const std = @import("std");
const base32 = @import("base32.zig");

pub const Principal = []const u8;

pub const managementCanister: Principal = &.{};
pub const anonymous: Principal = &.{0x04};

pub fn encode(principal: Principal) []const u8 {
    const src = std.heap.page_allocator.alloc(u8, 4 + principal.len) catch
        @panic("failed to allocate memory");
    const crc = std.hash.crc.Crc32IsoHdlc.hash(principal);
    std.mem.writeInt(u32, src[0..4], crc, .big);
    @memcpy(src[4..], principal);

    const dst = std.heap.page_allocator.alloc(u8, base32.encode_len(src.len)) catch
        @panic("failed to allocate memory");
    base32.std_encoding.encode(dst, src);
    std.heap.page_allocator.free(src);

    for (dst) |*c| {
        c.* = std.ascii.toLower(c.*);
    }

    const out = std.heap.page_allocator.alloc(u8, dst.len + (dst.len - 1) / 5) catch
        @panic("failed to allocate memory");
    insertDashes(out, dst);
    std.heap.page_allocator.free(dst);
    return out;
}

pub const DecodeError = base32.DecodeError || error{ InvalidChecksum, TooShort };

pub fn decode(text: []const u8) DecodeError!Principal {
    var slen: usize = 0;
    for (text) |c| {
        if (c != '-') slen += 1;
    }
    const decoded_total = slen * 5 / 8;
    if (decoded_total < 4) return error.TooShort;
    const buf = std.heap.page_allocator.alloc(u8, decoded_total) catch
        @panic("failed to allocate memory");
    const n = try base32.decode(buf, text);
    if (n < 4) return error.TooShort;
    return verifyChecksum(buf[0..n]);
}

fn verifyChecksum(buf: []const u8) DecodeError!Principal {
    const checksum = std.mem.readInt(u32, buf[0..4], .big);
    const data = buf[4..];
    const computed = std.hash.crc.Crc32IsoHdlc.hash(data);
    if (checksum != computed) return error.InvalidChecksum;
    return data;
}

fn insertDashes(out: []u8, src: []const u8) void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 1) {
        out[j] = src[i];
        j += 1;
        if (i % 5 == 4) {
            out[j] = '-';
            j += 1;
        }
    }
}

fn strippedLen(comptime text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c != '-') n += 1;
    }
    return n;
}

fn comptimeEncodeLen(comptime n: usize) usize {
    const b32_len = base32.encode_len(n);
    return b32_len + (b32_len - 1) / 5;
}

pub fn comptimeEncode(comptime principal: []const u8) *const [comptimeEncodeLen(4 + principal.len)]u8 {
    comptime {
        const crc = std.hash.crc.Crc32IsoHdlc.hash(principal);
        var src: [4 + principal.len]u8 = undefined;
        std.mem.writeInt(u32, src[0..4], crc, .big);
        @memcpy(src[4..], principal);

        const b32_len = base32.encode_len(src.len);
        var b32: [b32_len]u8 = undefined;
        base32.std_encoding.encode(&b32, &src);

        for (&b32) |*c| {
            c.* = std.ascii.toLower(c.*);
        }

        const out_len = b32_len + (b32_len - 1) / 5;
        var tmp: [out_len]u8 = undefined;
        insertDashes(&tmp, &b32);

        const out = tmp;
        return &out;
    }
}

pub fn comptimeDecode(comptime text: []const u8) *const [strippedLen(text) * 5 / 8 - 4]u8 {
    const slen = comptime strippedLen(text);
    const decoded_total = slen * 5 / 8;
    const principal_len = decoded_total - 4;

    comptime {
        var buf: [decoded_total]u8 = std.mem.zeroes([decoded_total]u8);
        const n = base32.decode(&buf, text) catch
            @compileError("invalid base32 character");
        const checksum = std.mem.readInt(u32, buf[0..4], .big);
        const result: [principal_len]u8 = buf[4..n][0..principal_len].*;
        const computed = std.hash.crc.Crc32IsoHdlc.hash(&result);
        if (checksum != computed) {
            @compileError("invalid principal checksum");
        }
        return &result;
    }
}

test "management canister" {
    try std.testing.expectEqualSlices(u8, "aaaaa-aa", encode(managementCanister));
}

test "anonymous" {
    try std.testing.expectEqualSlices(u8, "2vxsx-fae", encode(anonymous));
}

test "encode anonymous" {
    try std.testing.expectEqualSlices(u8, "2vxsx-fae", encode(&[_]u8{0x04}));
}

test "comptimeEncode anonymous" {
    const text = comptime comptimeEncode(&[_]u8{0x04});
    try std.testing.expectEqualSlices(u8, "2vxsx-fae", text);
}

test "comptimeDecode anonymous" {
    const p = comptime comptimeDecode("2vxsx-fae");
    try std.testing.expectEqualSlices(u8, &[_]u8{0x04}, p);
}

test "decode anonymous" {
    const p = try decode("2vxsx-fae");
    try std.testing.expectEqualSlices(u8, &[_]u8{0x04}, p);
}

test "decode invalid checksum" {
    try std.testing.expectError(error.InvalidChecksum, decode("2vxsx-faz"));
}

test "decode invalid character" {
    try std.testing.expectError(error.InvalidCharacter, decode("2vxsx-fa!"));
}

test "decode too short" {
    try std.testing.expectError(error.TooShort, decode("mv"));
}

test "comptimeDecode round-trip" {
    const text = "tz2ag-zx777-77776-aaabq-cai";
    const p = comptime comptimeDecode(text);
    try std.testing.expectEqualSlices(u8, text, encode(p));
}

test "comptimeEncode round-trip" {
    const principal = comptime comptimeDecode("tz2ag-zx777-77776-aaabq-cai");
    const text = comptime comptimeEncode(principal);
    try std.testing.expectEqualSlices(u8, "tz2ag-zx777-77776-aaabq-cai", text);
}
