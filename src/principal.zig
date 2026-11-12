const std = @import("std");
const base32 = @import("base32.zig");

const assert = @import("assert.zig").assert;

// The checksum prefixed to a textual principal (IC interface spec).
const Crc32 = std.hash.crc.@"CRC-32/ISO-HDLC";

/// Owns its bytes inline. The spec caps a principal at 29 bytes, so there is
/// nothing to allocate and nothing to borrow.
pub const Principal = struct {
    /// A principal is an opaque blob of at most 29 bytes, and its textual
    /// form is therefore at most 63 characters. Both are fixed by the spec.
    pub const max_bytes = 29;
    pub const max_text_len = 63;

    raw: [max_bytes]u8 = @splat(0),
    len: u8 = 0,

    /// Asserts the length. Use `tryFrom` for bytes from an untrusted source.
    pub fn from(bytes: []const u8) Principal {
        assert(bytes.len <= max_bytes, "principal is at most 29 bytes");
        var p = Principal{ .len = @intCast(bytes.len) };
        @memcpy(p.raw[0..bytes.len], bytes);
        return p;
    }

    pub fn tryFrom(bytes: []const u8) error{TooLong}!Principal {
        if (bytes.len > max_bytes) return error.TooLong;
        return from(bytes);
    }

    pub fn slice(self: *const Principal) []const u8 {
        return self.raw[0..self.len];
    }

    pub fn eql(self: Principal, other: Principal) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    pub fn isAnonymous(self: Principal) bool {
        return self.eql(anonymous);
    }

    pub fn class(self: Principal) Class {
        if (self.isAnonymous()) return .anonymous;
        if (self.len == 29) switch (self.raw[28]) {
            0x02 => return .self_authenticating,
            0x03 => return .derived,
            else => {},
        };
        return .unclassified;
    }
};

/// The classes a principal can be told apart into. Opaque and reserved ids
/// are both `.other`: the spec says opaque ids typically end in `0x01` but
/// that users should not rely on it, and that canister ids and user ids are
/// intentionally indistinguishable.
pub const Class = enum {
    /// `0x04`, the anonymous caller.
    anonymous,
    /// `H(public_key) · 0x02`. Holders of the matching private key can use
    /// this as the sender of a request.
    self_authenticating,
    /// `H(|registering_principal| · registering_principal · nonce) · 0x03`.
    derived,
    /// Opaque or reserved. Canister ids land here: the spec says opaque ids
    /// typically end in `0x01` but that users should not rely on it.
    unclassified,
};

pub const management_canister: Principal = .{};
pub const anonymous: Principal = blk: {
    var p = Principal{ .len = 1 };
    p.raw[0] = 0x04;
    break :blk p;
};

pub const Error = base32.DecodeError || error{ InvalidChecksum, TooShort, TooLong };

const checksummed_len = 4 + Principal.max_bytes;
const group_len = base32.encode_len(checksummed_len);

/// Write the textual form into `dest` and return the part written.
pub fn toText(dest: *[Principal.max_text_len]u8, p: Principal) []const u8 {
    const bytes = p.slice();

    var checksummed: [checksummed_len]u8 = undefined;
    std.mem.writeInt(u32, checksummed[0..4], Crc32.hash(bytes), .big);
    @memcpy(checksummed[4..][0..bytes.len], bytes);

    var groups: [group_len]u8 = undefined;
    const groups_used = base32.encode_len(4 + bytes.len);
    base32.std_encoding.encode(groups[0..groups_used], checksummed[0 .. 4 + bytes.len]);
    for (groups[0..groups_used]) |*c| c.* = std.ascii.toLower(c.*);

    const out_len = groups_used + (groups_used - 1) / 5;
    insertDashes(dest[0..out_len], groups[0..groups_used]);
    return dest[0..out_len];
}

pub fn fromText(text: []const u8) Error!Principal {
    var stripped: usize = 0;
    for (text) |c| {
        if (c != '-') stripped += 1;
    }
    const decoded_len = stripped * 5 / 8;
    if (decoded_len < 4) return error.TooShort;
    if (decoded_len - 4 > Principal.max_bytes) return error.TooLong;

    var checksummed: [checksummed_len]u8 = undefined;
    const n = try base32.decode(&checksummed, text);
    if (n < 4) return error.TooShort;

    var p = Principal{ .len = @intCast(n - 4) };
    @memcpy(p.raw[0 .. n - 4], checksummed[4..n]);

    const checksum = std.mem.readInt(u32, checksummed[0..4], .big);
    if (checksum != Crc32.hash(p.slice())) return error.InvalidChecksum;
    return p;
}

fn insertDashes(out: []u8, src: []const u8) void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 1) {
        out[j] = src[i];
        j += 1;
        if (i % 5 == 4 and i + 1 < src.len) {
            out[j] = '-';
            j += 1;
        }
    }
    assert(j == out.len, "textual principal length mismatch");
}

/// Only for the diagnostic: an invalid literal becomes a readable compile
/// error rather than a comptime `unreachable`.
pub fn comptimeFromText(comptime text: []const u8) Principal {
    return comptime fromText(text) catch
        @compileError("invalid principal: " ++ text);
}

test "toText" {
    var buf: [Principal.max_text_len]u8 = undefined;
    try std.testing.expectEqualStrings("aaaaa-aa", toText(&buf, management_canister));
    try std.testing.expectEqualStrings("2vxsx-fae", toText(&buf, anonymous));
}

test "toText at every length" {
    var text: [Principal.max_text_len]u8 = undefined;
    var bytes: [Principal.max_bytes]u8 = @splat(0xCA);

    for (0..Principal.max_bytes + 1) |n| {
        const p = Principal.from(bytes[0..n]);
        const round_tripped = try fromText(toText(&text, p));
        try std.testing.expect(p.eql(round_tripped));
    }
}

test "fromText" {
    const p = try fromText("2vxsx-fae");
    try std.testing.expectEqualSlices(u8, &[_]u8{0x04}, p.slice());
    try std.testing.expect(p.eql(anonymous));
}

test "fromText rejects bad input" {
    try std.testing.expectError(error.InvalidChecksum, fromText("2vxsx-faz"));
    try std.testing.expectError(error.InvalidCharacter, fromText("2vxsx-fa!"));
    try std.testing.expectError(error.TooShort, fromText("mv"));
}

test "class" {
    try std.testing.expectEqual(Class.anonymous, anonymous.class());
    try std.testing.expectEqual(Class.unclassified, management_canister.class());

    var bytes: [29]u8 = @splat(0);
    bytes[28] = 0x02;
    try std.testing.expectEqual(Class.self_authenticating, Principal.from(&bytes).class());

    bytes[28] = 0x03;
    try std.testing.expectEqual(Class.derived, Principal.from(&bytes).class());
}

test "comptime round-trip" {
    const text = "tz2ag-zx777-77776-aaabq-cai";
    const p = comptime comptimeFromText(text);

    var buf: [Principal.max_text_len]u8 = undefined;
    try std.testing.expectEqualStrings(text, toText(&buf, p));
}
