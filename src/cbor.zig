const std = @import("std");

pub const Error = error{
    EndOfInput,
    InvalidCbor,
    UnexpectedType,
    Overflow,
    OutOfMemory,
    TooDeep,
};

// CBOR major types
const MAJOR_UINT = 0;
const MAJOR_NINT = 1;
const MAJOR_BYTES = 2;
const MAJOR_TEXT = 3;
const MAJOR_ARRAY = 4;
const MAJOR_MAP = 5;
const MAJOR_TAG = 6;
const MAJOR_SIMPLE = 7;

// Encoding

pub fn encodedSize(value: anytype) usize {
    const T = @TypeOf(value);
    if (comptime hasHook(T, "cborEncode")) return encodedSize(value.cborEncode());
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isByteString(T)) return headSize(value.data.len) + value.data.len;
            if (T == Encoded) return value.data.len;
            if (comptime hasKeys(T)) {
                var size: usize = 0;
                var present: u64 = 0;
                inline for (info.field_names) |name| {
                    const field = @field(value, name);
                    if (!isNull(field)) {
                        present += 1;
                        size += headSize(fieldKey(T, name)) + encodedSize(field);
                    }
                }
                return headSize(present) + size;
            }
            var size = headSize(info.field_names.len);
            inline for (info.field_names) |name| {
                if (!info.is_tuple) size += headSize(name.len) + name.len;
                size += encodedSize(@field(value, name));
            }
            return size;
        },
        .pointer => |ptr_info| {
            if (comptime isText(T)) {
                return headSize(value.len) + value.len;
            }
            if (ptr_info.size == .slice) {
                var size = headSize(value.len);
                for (value) |elem| size += encodedSize(elem);
                return size;
            }
            if (ptr_info.size == .one) return encodedSize(value.*);
            @compileError("unsupported pointer type: " ++ @typeName(T));
        },
        .array => |a| {
            if (a.child == u8) return headSize(value.len) + value.len;
            var size = headSize(value.len);
            for (value) |elem| size += encodedSize(elem);
            return size;
        },
        .int, .comptime_int => {
            // A comptime_int as the smallest type that holds it.
            const I = if (T == comptime_int) std.math.IntFittingRange(value, value) else T;
            const n = intParts(I, value);
            if (n.magnitude <= std.math.maxInt(u64)) return headSize(@intCast(n.magnitude));
            const len = bignumLen(n.magnitude);
            return 1 + headSize(len) + len;
        },
        .float, .comptime_float => return switch (floatWidth(value)) {
            .half => 3,
            .single => 5,
            .double => 9,
        },
        .bool, .null => return 1,
        .optional => return if (value) |v| encodedSize(v) else 1,
        .@"enum" => {
            const name = @tagName(value);
            return headSize(name.len) + name.len;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

/// A type can stand in as another, say a byte string:
///
///     pub fn cborEncode(self: *const T) cbor.ByteString
///     pub fn cborDecode(b: cbor.ByteString) !T
///
/// What `cborEncode` returns may borrow from `self`.
fn hasHook(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, name),
        else => false,
    };
}

/// A struct declaring `cbor_keys`, say `.{ .at = 0, .amount = 1 }`, is a map
/// from those integer keys instead of field names, as minicbor writes it.
/// Null optionals are left out. Keys must be unique and cover every field.
fn hasKeys(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "cbor_keys");
}

fn fieldKey(comptime T: type, comptime name: []const u8) u64 {
    return comptime blk: {
        const keys = T.cbor_keys;
        if (!@hasField(@TypeOf(keys), name))
            @compileError(@typeName(T) ++ ".cbor_keys has no key for " ++ name);
        for (@typeInfo(T).@"struct".field_names) |other| {
            if (!std.mem.eql(u8, other, name) and @hasField(@TypeOf(keys), other) and
                @field(keys, other) == @field(keys, name))
                @compileError(@typeName(T) ++ ".cbor_keys repeats a key for " ++ name);
        }
        break :blk @field(keys, name);
    };
}

fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        else => false,
    };
}

// []const u8 and pointers to u8 arrays, string literals among them.
fn isText(comptime T: type) bool {
    const p = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return switch (p.size) {
        .slice => p.child == u8,
        .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
        else => false,
    };
}

// An integer is n, or -1 - n when negative. `M` holds n for any `T`.
fn IntParts(comptime T: type) type {
    const bits = @typeInfo(T).int.bits;
    return struct {
        negative: bool,
        magnitude: Magnitude,

        // Whole bytes, at least 64 bits so a u64 head always fits.
        const Magnitude = @Int(.unsigned, std.mem.alignForward(u16, @max(bits, 64), 8));
    };
}

fn intParts(comptime T: type, value: T) IntParts(T) {
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (value < 0) return .{ .negative = true, .magnitude = @intCast(-1 - value) };
    }
    return .{ .negative = false, .magnitude = @intCast(value) };
}

// Bytes of a bignum, beyond 64 bits, without leading zeros.
fn bignumLen(magnitude: anytype) usize {
    const bits = @typeInfo(@TypeOf(magnitude)).int.bits;
    return (bits - @clz(magnitude) + 7) / 8;
}

const FloatWidth = enum { half, single, double };

// Preferred serialization (RFC 8949 4.2): the narrowest width that keeps the
// value. NaN is always written as the half-precision quiet NaN.
fn floatWidth(value: anytype) FloatWidth {
    const v: f64 = value;
    if (std.math.isNan(v) or std.math.isInf(v)) return .half;
    const a = @abs(v);
    if (a <= std.math.floatMax(f16) and @as(f64, @as(f16, @floatCast(v))) == v) return .half;
    if (a <= std.math.floatMax(f32) and @as(f64, @as(f32, @floatCast(v))) == v) return .single;
    return .double;
}

/// Encode into memory from `a`.
pub fn encodeAlloc(a: std.mem.Allocator, value: anytype) error{OutOfMemory}![]const u8 {
    const buf = try a.alloc(u8, encodedSize(value));
    return encode(buf, value);
}

pub fn headSize(val: u64) usize {
    if (val < 24) return 1;
    if (val <= 0xFF) return 2;
    if (val <= 0xFFFF) return 3;
    if (val <= 0xFFFFFFFF) return 5;
    return 9;
}

pub fn encode(buf: []u8, value: anytype) []const u8 {
    var pos: usize = 0;
    encodeInto(buf, &pos, value);
    return buf[0..pos];
}

fn encodeInto(buf: []u8, pos: *usize, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime hasHook(T, "cborEncode")) return encodeInto(buf, pos, value.cborEncode());
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isByteString(T)) {
                writeHead(buf, pos, MAJOR_BYTES, value.data.len);
                @memcpy(buf[pos.*..][0..value.data.len], value.data);
                pos.* += value.data.len;
                return;
            }
            if (T == Encoded) {
                @memcpy(buf[pos.*..][0..value.data.len], value.data);
                pos.* += value.data.len;
                return;
            }
            if (comptime hasKeys(T)) {
                var present: u64 = 0;
                inline for (info.field_names) |name| {
                    if (!isNull(@field(value, name))) present += 1;
                }
                writeHead(buf, pos, MAJOR_MAP, present);
                inline for (info.field_names) |name| {
                    const field = @field(value, name);
                    if (!isNull(field)) {
                        writeHead(buf, pos, MAJOR_UINT, fieldKey(T, name));
                        encodeInto(buf, pos, field);
                    }
                }
                return;
            }
            const major: u3 = if (info.is_tuple) MAJOR_ARRAY else MAJOR_MAP;
            writeHead(buf, pos, major, info.field_names.len);
            inline for (info.field_names) |name| {
                if (!info.is_tuple) {
                    writeHead(buf, pos, MAJOR_TEXT, name.len);
                    @memcpy(buf[pos.*..][0..name.len], name);
                    pos.* += name.len;
                }
                encodeInto(buf, pos, @field(value, name));
            }
        },
        .pointer => |ptr_info| {
            if (comptime isText(T)) {
                writeHead(buf, pos, MAJOR_TEXT, value.len);
                @memcpy(buf[pos.*..][0..value.len], value);
                pos.* += value.len;
                return;
            }
            if (ptr_info.size == .slice) {
                writeHead(buf, pos, MAJOR_ARRAY, value.len);
                for (value) |elem| encodeInto(buf, pos, elem);
                return;
            }
            if (ptr_info.size == .one) {
                encodeInto(buf, pos, value.*);
                return;
            }
            @compileError("unsupported pointer type: " ++ @typeName(T));
        },
        .array => |a| {
            if (a.child == u8) {
                writeHead(buf, pos, MAJOR_BYTES, value.len);
                @memcpy(buf[pos.*..][0..value.len], &value);
                pos.* += value.len;
                return;
            }
            writeHead(buf, pos, MAJOR_ARRAY, value.len);
            for (value) |elem| encodeInto(buf, pos, elem);
        },
        .int, .comptime_int => {
            const I = if (T == comptime_int) std.math.IntFittingRange(value, value) else T;
            const n = intParts(I, value);
            if (n.magnitude <= std.math.maxInt(u64)) {
                const major: u3 = if (n.negative) MAJOR_NINT else MAJOR_UINT;
                writeHead(buf, pos, major, @intCast(n.magnitude));
                return;
            }
            // Tag 2 or 3, then the magnitude as a big-endian byte string.
            writeHead(buf, pos, MAJOR_TAG, if (n.negative) 3 else 2);
            const len = bignumLen(n.magnitude);
            writeHead(buf, pos, MAJOR_BYTES, len);
            const M = @TypeOf(n.magnitude);
            var be: [@typeInfo(M).int.bits / 8]u8 = undefined;
            std.mem.writeInt(M, &be, n.magnitude, .big);
            @memcpy(buf[pos.*..][0..len], be[be.len - len ..]);
            pos.* += len;
        },
        .float, .comptime_float => {
            const v: f64 = value;
            switch (floatWidth(value)) {
                .half => {
                    buf[pos.*] = 0xf9;
                    const h: f16 = if (std.math.isNan(v)) std.math.nan(f16) else @floatCast(v);
                    std.mem.writeInt(u16, buf[pos.* + 1 ..][0..2], @bitCast(h), .big);
                    pos.* += 3;
                },
                .single => {
                    buf[pos.*] = 0xfa;
                    const s: f32 = @floatCast(v);
                    std.mem.writeInt(u32, buf[pos.* + 1 ..][0..4], @bitCast(s), .big);
                    pos.* += 5;
                },
                .double => {
                    buf[pos.*] = 0xfb;
                    std.mem.writeInt(u64, buf[pos.* + 1 ..][0..8], @bitCast(v), .big);
                    pos.* += 9;
                },
            }
        },
        .bool => writeSimple(buf, pos, if (value) 21 else 20),
        .null => writeSimple(buf, pos, 22),
        .optional => if (value) |v| encodeInto(buf, pos, v) else writeSimple(buf, pos, 22),
        .@"enum" => {
            const name = @tagName(value);
            writeHead(buf, pos, MAJOR_TEXT, name.len);
            @memcpy(buf[pos.*..][0..name.len], name);
            pos.* += name.len;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

// false, true and null are simple values 20, 21 and 22.
fn writeSimple(buf: []u8, pos: *usize, simple: u5) void {
    writeHead(buf, pos, MAJOR_SIMPLE, simple);
}

pub fn writeHead(buf: []u8, pos: *usize, major: u3, val: u64) void {
    const m: u8 = @as(u8, major) << 5;
    if (val < 24) {
        buf[pos.*] = m | @as(u8, @intCast(val));
        pos.* += 1;
    } else if (val <= 0xFF) {
        buf[pos.*] = m | 24;
        buf[pos.* + 1] = @intCast(val);
        pos.* += 2;
    } else if (val <= 0xFFFF) {
        buf[pos.*] = m | 25;
        std.mem.writeInt(u16, buf[pos.* + 1 ..][0..2], @intCast(val), .big);
        pos.* += 3;
    } else if (val <= 0xFFFFFFFF) {
        buf[pos.*] = m | 26;
        std.mem.writeInt(u32, buf[pos.* + 1 ..][0..4], @intCast(val), .big);
        pos.* += 5;
    } else {
        buf[pos.*] = m | 27;
        std.mem.writeInt(u64, buf[pos.* + 1 ..][0..8], @intCast(val), .big);
        pos.* += 9;
    }
}

// Wrapper to mark a []const u8 as a CBOR byte string (major type 2)
// instead of a text string (major type 3).
pub const ByteString = struct {
    data: []const u8,

    pub fn from(d: []const u8) ByteString {
        return .{ .data = d };
    }
};

/// A value already encoded as CBOR, written as it is.
pub const Encoded = struct {
    data: []const u8,
};

fn isByteString(comptime T: type) bool {
    return T == ByteString;
}

// Decoding

pub const Value = union(enum) {
    uint: u64,
    nint: u64,
    bytes: []const u8,
    text: []const u8,
    array: []const u8,
    map: []const u8,
    tag: struct { number: u64, content: []const u8 },
    simple: u8,
    float: f64,
};

pub fn decodeValue(data: []const u8) Error!struct { value: Value, rest: []const u8 } {
    if (data.len == 0) return Error.EndOfInput;
    const initial = data[0];
    const major: u3 = @intCast(initial >> 5);
    const additional: u5 = @intCast(initial & 0x1f);
    var pos: usize = 1;

    const val = try readArgument(data, additional, &pos);

    switch (major) {
        MAJOR_UINT => return .{ .value = .{ .uint = val }, .rest = data[pos..] },
        MAJOR_NINT => return .{ .value = .{ .nint = val }, .rest = data[pos..] },
        MAJOR_BYTES => {
            const len = try fits(data, pos, val, 1);
            return .{ .value = .{ .bytes = data[pos .. pos + len] }, .rest = data[pos + len ..] };
        },
        MAJOR_TEXT => {
            const len = try fits(data, pos, val, 1);
            return .{ .value = .{ .text = data[pos .. pos + len] }, .rest = data[pos + len ..] };
        },
        MAJOR_ARRAY => {
            const count = try fits(data, pos, val, 1);
            const start = pos;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                pos += try skipValueAt(data[pos..]);
            }
            return .{ .value = .{ .array = data[start..pos] }, .rest = data[pos..] };
        },
        MAJOR_MAP => {
            const count = try fits(data, pos, val, 2);
            const start = pos;
            var i: usize = 0;
            while (i < count * 2) : (i += 1) {
                pos += try skipValueAt(data[pos..]);
            }
            return .{ .value = .{ .map = data[start..pos] }, .rest = data[pos..] };
        },
        MAJOR_TAG => {
            const content_start = pos;
            pos += try skipValueAt(data[pos..]);
            return .{
                .value = .{ .tag = .{ .number = val, .content = data[content_start..pos] } },
                .rest = data[pos..],
            };
        },
        MAJOR_SIMPLE => {
            const value: Value = switch (additional) {
                25 => .{ .float = @as(f16, @bitCast(@as(u16, @intCast(val)))) },
                26 => .{ .float = @as(f32, @bitCast(@as(u32, @intCast(val)))) },
                27 => .{ .float = @bitCast(val) },
                else => .{ .simple = @intCast(val) },
            };
            return .{ .value = value, .rest = data[pos..] };
        },
    }
}

fn readArgument(data: []const u8, additional: u5, pos: *usize) Error!u64 {
    if (additional < 24) return @intCast(additional);
    switch (additional) {
        24 => {
            if (pos.* >= data.len) return Error.EndOfInput;
            const v = data[pos.*];
            pos.* += 1;
            return @intCast(v);
        },
        25 => {
            if (pos.* + 2 > data.len) return Error.EndOfInput;
            const v = std.mem.readInt(u16, data[pos.*..][0..2], .big);
            pos.* += 2;
            return @intCast(v);
        },
        26 => {
            if (pos.* + 4 > data.len) return Error.EndOfInput;
            const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
            pos.* += 4;
            return @intCast(v);
        },
        27 => {
            if (pos.* + 8 > data.len) return Error.EndOfInput;
            const v = std.mem.readInt(u64, data[pos.*..][0..8], .big);
            pos.* += 8;
            return v;
        },
        else => return Error.InvalidCbor,
    }
}

/// How deeply arrays, maps and tags may nest. Decoding recurses per level, so
/// this bounds the stack a hostile input can use.
pub const max_depth = 64;

// `val` as a count of items at least `min_size` bytes each, if that many fit
// in what follows `pos`.
fn fits(data: []const u8, pos: usize, val: u64, min_size: usize) Error!usize {
    const room: u64 = (data.len - pos) / min_size;
    if (val > room) return Error.EndOfInput;
    return @intCast(val);
}

fn skipValueAt(data: []const u8) Error!usize {
    return skipNested(data, 0);
}

fn skipNested(data: []const u8, depth: usize) Error!usize {
    if (data.len == 0) return Error.EndOfInput;
    if (depth > max_depth) return Error.TooDeep;
    const initial = data[0];
    const major: u3 = @intCast(initial >> 5);
    const additional: u5 = @intCast(initial & 0x1f);
    var pos: usize = 1;

    const val = try readArgument(data, additional, &pos);

    switch (major) {
        MAJOR_UINT, MAJOR_NINT, MAJOR_SIMPLE => return pos,
        MAJOR_BYTES, MAJOR_TEXT => return pos + try fits(data, pos, val, 1),
        MAJOR_ARRAY, MAJOR_MAP => {
            const per_item: usize = if (major == MAJOR_MAP) 2 else 1;
            const items = try fits(data, pos, val, per_item) * per_item;
            var i: usize = 0;
            while (i < items) : (i += 1) {
                pos += try skipNested(data[pos..], depth + 1);
            }
            return pos;
        },
        MAJOR_TAG => {
            pos += try skipNested(data[pos..], depth + 1);
            return pos;
        },
    }
}

// Map lookup: find a text key in CBOR map content bytes.
pub fn mapLookup(map_content: []const u8, key: []const u8) Error!?Value {
    var remaining = map_content;
    while (remaining.len > 0) {
        const k = try decodeValue(remaining);
        remaining = k.rest;
        const v = try decodeValue(remaining);
        remaining = v.rest;
        switch (k.value) {
            .text => |t| {
                if (std.mem.eql(u8, t, key)) return v.value;
            },
            else => {},
        }
    }
    return null;
}

// Map lookup returning raw bytes: find a text key in CBOR map content
// and return the raw encoded bytes of the value.
pub fn mapLookupRaw(map_content: []const u8, key: []const u8) Error!?[]const u8 {
    var remaining = map_content;
    while (remaining.len > 0) {
        const k = try decodeValue(remaining);
        const val_start = k.rest;
        const v = try decodeValue(val_start);
        switch (k.value) {
            .text => |t| {
                if (std.mem.eql(u8, t, key)) {
                    const val_len = @intFromPtr(v.rest.ptr) - @intFromPtr(val_start.ptr);
                    return val_start[0..val_len];
                }
            },
            else => {},
        }
        remaining = v.rest;
    }
    return null;
}

// Typed decoding

pub const DecodeError = Error || error{
    TrailingBytes,
    MissingField,
    DuplicateField,
    UnknownVariant,
    LengthMismatch,
    /// A `cborDecode` hook refused what it was given.
    InvalidValue,
};

/// Decode one data item, all of `bytes`, into a `T`: the types `encode`
/// writes, read back the same way. Text and byte strings borrow from `bytes`,
/// slices are allocated from `a`. A struct skips keys it does not know, and
/// a missing field takes its default, or null if optional.
pub fn decode(comptime T: type, a: std.mem.Allocator, bytes: []const u8) DecodeError!T {
    var d: Decoder = .{ .data = bytes, .a = a };
    const value = try d.item(T);
    if (d.pos != bytes.len) return error.TrailingBytes;
    return value;
}

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    a: std.mem.Allocator,

    const Head = struct { major: u3, additional: u5, arg: u64 };

    fn head(d: *Decoder) Error!Head {
        if (d.pos >= d.data.len) return error.EndOfInput;
        const initial = d.data[d.pos];
        d.pos += 1;
        const additional: u5 = @intCast(initial & 0x1f);
        return .{
            .major = @intCast(initial >> 5),
            .additional = additional,
            .arg = try readArgument(d.data, additional, &d.pos),
        };
    }

    fn expect(d: *Decoder, major: u3) Error!u64 {
        const h = try d.head();
        if (h.major != major) return error.UnexpectedType;
        return h.arg;
    }

    // Text must be UTF-8 to be valid CBOR (RFC 8949 5.3.1).
    fn string(d: *Decoder, major: u3) Error![]const u8 {
        const len = try fits(d.data, d.pos, try d.expect(major), 1);
        const s = d.data[d.pos..][0..len];
        if (major == MAJOR_TEXT and !std.unicode.utf8ValidateSlice(s)) return error.InvalidCbor;
        d.pos += len;
        return s;
    }

    fn count(d: *Decoder, major: u3) Error!usize {
        return fits(d.data, d.pos, try d.expect(major), if (major == MAJOR_MAP) 2 else 1);
    }

    fn skip(d: *Decoder) Error!void {
        d.pos += try skipNested(d.data[d.pos..], d.depth);
    }

    fn nextIsNull(d: *Decoder) bool {
        return d.pos < d.data.len and d.data[d.pos] == 0xf6;
    }

    fn item(d: *Decoder, comptime T: type) DecodeError!T {
        if (T == Encoded) {
            const start = d.pos;
            try d.skip();
            return .{ .data = d.data[start..d.pos] };
        }
        if (T == ByteString) return .{ .data = try d.string(MAJOR_BYTES) };
        if (comptime hasHook(T, "cborDecode")) {
            const Repr = @typeInfo(@TypeOf(T.cborDecode)).@"fn".param_types[0].?;
            return T.cborDecode(try d.item(Repr)) catch error.InvalidValue;
        }

        d.depth += 1;
        defer d.depth -= 1;
        if (d.depth > max_depth) return error.TooDeep;

        switch (@typeInfo(T)) {
            .bool => {
                const h = try d.head();
                if (h.major == MAJOR_SIMPLE and h.additional == 20) return false;
                if (h.major == MAJOR_SIMPLE and h.additional == 21) return true;
                return error.UnexpectedType;
            },
            .optional => |o| {
                if (!d.nextIsNull()) return try d.item(o.child);
                d.pos += 1;
                return null;
            },
            .int => return d.int(T),
            .float => return d.float(T),
            .@"enum" => return std.meta.stringToEnum(T, try d.string(MAJOR_TEXT)) orelse
                error.UnknownVariant,
            .array => |arr| {
                if (arr.child == u8) {
                    const s = try d.string(MAJOR_BYTES);
                    if (s.len != arr.len) return error.LengthMismatch;
                    return s[0..arr.len].*;
                }
                if (try d.count(MAJOR_ARRAY) != arr.len) return error.LengthMismatch;
                var out: T = undefined;
                for (&out) |*e| e.* = try d.item(arr.child);
                return out;
            },
            .pointer => |p| {
                if (p.size != .slice or !p.attrs.@"const" or p.sentinel_ptr != null)
                    @compileError("decode reads []const T, not " ++ @typeName(T));
                if (p.child == u8) return d.string(MAJOR_TEXT);
                const out = try d.a.alloc(p.child, try d.count(MAJOR_ARRAY));
                for (out) |*e| e.* = try d.item(p.child);
                return out;
            },
            .@"struct" => |s| {
                if (!s.is_tuple) return d.record(T);
                if (try d.count(MAJOR_ARRAY) != s.field_names.len) return error.LengthMismatch;
                var out: T = undefined;
                inline for (s.field_names, s.field_types) |name, F| {
                    @field(out, name) = try d.item(F);
                }
                return out;
            },
            else => @compileError("cannot decode " ++ @typeName(T)),
        }
    }

    fn int(d: *Decoder, comptime T: type) DecodeError!T {
        const h = try d.head();
        switch (h.major) {
            MAJOR_UINT => return std.math.cast(T, h.arg) orelse error.Overflow,
            MAJOR_NINT => return std.math.cast(T, -1 - @as(i128, h.arg)) orelse error.Overflow,
            MAJOR_TAG => {
                if (h.arg != 2 and h.arg != 3) return error.UnexpectedType;
                const M = IntParts(T).Magnitude;
                const bytes = std.mem.trimStart(u8, try d.string(MAJOR_BYTES), "\x00");
                if (bytes.len > @typeInfo(M).int.bits / 8) return error.Overflow;
                var magnitude: M = 0;
                for (bytes) |b| magnitude = (magnitude << 8) | b;
                if (h.arg == 2) return std.math.cast(T, magnitude) orelse error.Overflow;
                // -1 - n, computed one bit wider so it cannot overflow.
                const S = @Int(.signed, @typeInfo(M).int.bits + 1);
                return std.math.cast(T, -1 - @as(S, magnitude)) orelse error.Overflow;
            },
            else => return error.UnexpectedType,
        }
    }

    // Any width, as long as the value fits `T` exactly.
    fn float(d: *Decoder, comptime T: type) DecodeError!T {
        const h = try d.head();
        if (h.major != MAJOR_SIMPLE) return error.UnexpectedType;
        const v: f64 = switch (h.additional) {
            25 => @as(f16, @bitCast(@as(u16, @intCast(h.arg)))),
            26 => @as(f32, @bitCast(@as(u32, @intCast(h.arg)))),
            27 => @bitCast(h.arg),
            else => return error.UnexpectedType,
        };
        if (std.math.isNan(v)) return std.math.nan(T);
        if (std.math.isInf(v)) return if (v > 0) std.math.inf(T) else -std.math.inf(T);
        if (@abs(v) > std.math.floatMax(T)) return error.Overflow;
        const out: T = @floatCast(v);
        if (@as(f64, out) != v) return error.Overflow;
        return out;
    }

    fn record(d: *Decoder, comptime T: type) DecodeError!T {
        const info = @typeInfo(T).@"struct";
        var out: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);

        const entries = try d.count(MAJOR_MAP);
        for (0..entries) |_| {
            const index = try d.fieldIndex(T) orelse {
                try d.skip();
                continue;
            };
            inline for (info.field_names, info.field_types, 0..) |name, F, i| {
                if (i == index) {
                    if (seen[i]) return error.DuplicateField;
                    seen[i] = true;
                    @field(out, name) = try d.item(F);
                }
            }
        }

        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (!seen[i]) {
                if (comptime attrs.defaultValue(F)) |default| {
                    @field(out, name) = default;
                } else if (@typeInfo(F) == .optional) {
                    @field(out, name) = null;
                } else return error.MissingField;
            }
        }
        return out;
    }

    // Reads a key, and returns the field it names, or null to skip its value.
    fn fieldIndex(d: *Decoder, comptime T: type) DecodeError!?usize {
        const names = @typeInfo(T).@"struct".field_names;
        const start = d.pos;
        const h = try d.head();
        const want: u3 = if (comptime hasKeys(T)) MAJOR_UINT else MAJOR_TEXT;
        if (h.major != want) {
            d.pos = start;
            try d.skip();
            return null;
        }
        if (comptime hasKeys(T)) {
            inline for (names, 0..) |name, i| {
                if (h.arg == fieldKey(T, name)) return i;
            }
            return null;
        }
        d.pos = start;
        const key = try d.string(MAJOR_TEXT);
        inline for (names, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) return i;
        }
        return null;
    }
};

// CBOR self-describe tag (55799)
pub fn withSelfDescribeTag(buf: []u8, inner: []const u8) []const u8 {
    buf[0] = 0xd9;
    buf[1] = 0xd9;
    buf[2] = 0xf7;
    @memcpy(buf[3..][0..inner.len], inner);
    return buf[0 .. 3 + inner.len];
}

fn expectEncodes(comptime hex: []const u8, value: anytype) !void {
    var want: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, hex);
    const got = try encodeAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &want, got);
}

// RFC 8949 Appendix A, the examples within what `encode` produces.
test "RFC 8949 examples" {
    try expectEncodes("00", 0);
    try expectEncodes("01", 1);
    try expectEncodes("0a", 10);
    try expectEncodes("17", 23);
    try expectEncodes("1818", 24);
    try expectEncodes("1819", 25);
    try expectEncodes("1864", 100);
    try expectEncodes("1903e8", 1000);
    try expectEncodes("1a000f4240", 1000000);
    try expectEncodes("1b000000e8d4a51000", 1000000000000);
    try expectEncodes("1bffffffffffffffff", @as(u64, 18446744073709551615));
    try expectEncodes("3bffffffffffffffff", @as(i128, -18446744073709551616));
    try expectEncodes("20", -1);
    try expectEncodes("29", -10);
    try expectEncodes("3863", -100);
    try expectEncodes("3903e7", @as(i32, -1000));
    try expectEncodes("c249010000000000000000", @as(u128, 18446744073709551616));
    try expectEncodes("c349010000000000000000", @as(i128, -18446744073709551617));

    try expectEncodes("f90000", @as(f64, 0.0));
    try expectEncodes("f98000", -@as(f64, 0.0));
    try expectEncodes("f93c00", @as(f64, 1.0));
    try expectEncodes("fb3ff199999999999a", @as(f64, 1.1));
    try expectEncodes("f93e00", @as(f64, 1.5));
    try expectEncodes("f97bff", @as(f64, 65504.0));
    try expectEncodes("fa47c35000", @as(f64, 100000.0));
    try expectEncodes("fa7f7fffff", @as(f64, 3.4028234663852886e+38));
    try expectEncodes("fb7e37e43c8800759c", @as(f64, 1.0e+300));
    try expectEncodes("f90001", @as(f64, 5.960464477539063e-8));
    try expectEncodes("f90400", @as(f64, 0.00006103515625));
    try expectEncodes("f9c400", @as(f64, -4.0));
    try expectEncodes("fbc010666666666666", @as(f64, -4.1));
    try expectEncodes("f97c00", std.math.inf(f64));
    try expectEncodes("f97e00", std.math.nan(f64));
    try expectEncodes("f9fc00", -std.math.inf(f64));

    try expectEncodes("f4", false);
    try expectEncodes("f5", true);
    try expectEncodes("f6", null);

    try expectEncodes("40", ByteString.from(""));
    try expectEncodes("4401020304", [_]u8{ 1, 2, 3, 4 });
    try expectEncodes("60", @as([]const u8, ""));
    try expectEncodes("6161", @as([]const u8, "a"));
    try expectEncodes("6449455446", @as([]const u8, "IETF"));
    try expectEncodes("62225c", @as([]const u8, "\"\\"));
    try expectEncodes("62c3bc", @as([]const u8, "\u{00fc}"));
    try expectEncodes("63e6b0b4", @as([]const u8, "\u{6c34}"));
    try expectEncodes("64f0908591", @as([]const u8, "\u{10151}"));

    try expectEncodes("80", @as([]const u64, &.{}));
    try expectEncodes("83010203", [_]u64{ 1, 2, 3 });
    try expectEncodes("8301820203820405", .{ 1, [_]u64{ 2, 3 }, [_]u64{ 4, 5 } });
    var seq: [25]u64 = undefined;
    for (&seq, 1..) |*x, i| x.* = i;
    try expectEncodes("98190102030405060708090a0b0c0d0e0f101112131415161718181819", seq);

    // An empty map. `.{}` is an empty tuple, which is an array.
    try expectEncodes("a0", struct {}{});
    try expectEncodes("80", .{});
    try expectEncodes("a26161016162820203", .{ .a = @as(u64, 1), .b = [_]u64{ 2, 3 } });
    try expectEncodes("826161a161626163", .{ "a", .{ .b = "c" } });
    try expectEncodes("a56161614161626142616361436164614461656145", .{
        .a = @as([]const u8, "A"),
        .b = @as([]const u8, "B"),
        .c = @as([]const u8, "C"),
        .d = @as([]const u8, "D"),
        .e = @as([]const u8, "E"),
    });
}

const KeyedPair = struct {
    a: u64,
    b: u64,
    pub const cbor_keys = .{ .a = 1, .b = 3 };
};

test "RFC 8949 example with integer keys" {
    try expectEncodes("a201020304", KeyedPair{ .a = 2, .b = 4 });
    try expectDecodes(KeyedPair, "a201020304", .{ .a = 2, .b = 4 });
}

fn expectDecodes(comptime T: type, comptime hex: []const u8, want: T) !void {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualDeep(want, try decode(T, arena.allocator(), &bytes));
}

fn expectDecodeError(comptime T: type, comptime hex: []const u8, want: anyerror) !void {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(want, decode(T, arena.allocator(), &bytes));
}

// RFC 8949 Appendix A read back, non-preferred float widths included.
test "decode RFC 8949 examples" {
    try expectDecodes(u8, "00", 0);
    try expectDecodes(u8, "17", 23);
    try expectDecodes(u16, "1903e8", 1000);
    try expectDecodes(u64, "1b000000e8d4a51000", 1000000000000);
    try expectDecodes(u64, "1bffffffffffffffff", 18446744073709551615);
    try expectDecodes(u128, "c249010000000000000000", 18446744073709551616);
    try expectDecodes(i128, "3bffffffffffffffff", -18446744073709551616);
    try expectDecodes(i128, "c349010000000000000000", -18446744073709551617);
    try expectDecodes(i8, "20", -1);
    try expectDecodes(i16, "3903e7", -1000);

    try expectDecodes(f64, "fb3ff199999999999a", 1.1);
    try expectDecodes(f32, "f93e00", 1.5);
    try expectDecodes(f64, "fa47c35000", 100000.0);
    try expectDecodes(f64, "f90001", 5.960464477539063e-8);
    try expectDecodes(f64, "fbc010666666666666", -4.1);
    try expectDecodes(f64, "fa7f800000", std.math.inf(f64));
    try expectDecodes(f64, "fbfff0000000000000", -std.math.inf(f64));
    const nan = "\xfb\x7f\xf8\x00\x00\x00\x00\x00\x00";
    try std.testing.expect(std.math.isNan(try decode(f64, std.testing.allocator, nan)));

    try expectDecodes(bool, "f4", false);
    try expectDecodes(bool, "f5", true);
    try expectDecodes(?u64, "f6", null);

    try expectDecodes([4]u8, "4401020304", .{ 1, 2, 3, 4 });
    try expectDecodes([]const u8, "6449455446", "IETF");
    try expectDecodes([]const u8, "64f0908591", "\u{10151}");

    try expectDecodes([]const u64, "80", &.{});
    try expectDecodes([3]u64, "83010203", .{ 1, 2, 3 });
    const Nested = struct { u64, [2]u64, [2]u64 };
    try expectDecodes(Nested, "8301820203820405", .{ 1, .{ 2, 3 }, .{ 4, 5 } });
    const Mixed = struct { []const u8, struct { b: []const u8 } };
    try expectDecodes(Mixed, "826161a161626163", .{ "a", .{ .b = "c" } });
    const Named = struct { a: u64, b: []const u64 };
    try expectDecodes(Named, "a26161016162820203", .{ .a = 1, .b = &.{ 2, 3 } });
}

test "decode rejects what it does not read" {
    // Indefinite lengths, from Appendix A.
    try expectDecodeError([]const u64, "9fff", error.InvalidCbor);
    try expectDecodeError([]const u8, "7f657374726561646d696e67ff", error.InvalidCbor);
    // A float that f32 cannot hold exactly.
    try expectDecodeError(f32, "fb3ff199999999999a", error.Overflow);
    try expectDecodeError(u8, "1903e8", error.Overflow);
    try expectDecodeError(u64, "20", error.Overflow);
    try expectDecodeError(u64, "0000", error.TrailingBytes);
    try expectDecodeError(KeyedPair, "a10102", error.MissingField);
    try expectDecodeError(KeyedPair, "a3010201020304", error.DuplicateField);
}

test "bignums of any width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Tag 2, a 26-byte string, then 2^200 big-endian.
    const big: u256 = 1 << 200;
    const bytes = try encodeAlloc(a, big);
    const zeros: [25]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0xc2, 0x58, 26, 1 } ++ zeros), bytes);
    try std.testing.expectEqual(big, try decode(u256, a, bytes));
    try std.testing.expectError(error.Overflow, decode(u128, a, bytes));

    const max: u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(max, try decode(u256, a, try encodeAlloc(a, max)));
    const min: i256 = std.math.minInt(i256);
    try std.testing.expectEqual(min, try decode(i256, a, try encodeAlloc(a, min)));
    try std.testing.expectError(error.Overflow, decode(i128, a, try encodeAlloc(a, min)));

    // A comptime_int takes the smallest type that holds it.
    const literal = try encodeAlloc(a, 1 << 100);
    try std.testing.expectEqualSlices(u8, try encodeAlloc(a, @as(u128, 1 << 100)), literal);

    // Leading zero bytes carry no value.
    try std.testing.expectEqual(@as(u8, 5), try decode(u8, a, "\xc2\x42\x00\x05"));
}

test "decode rejects text that is not UTF-8" {
    try expectDecodeError([]const u8, "62c328", error.InvalidCbor);
}

test "decodeValue reads floats" {
    const got = try decodeValue("\xf9\x3e\x00");
    try std.testing.expectEqual(@as(f64, 1.5), got.value.float);
    const simple = try decodeValue("\xf8\xff");
    try std.testing.expectEqual(@as(u8, 255), simple.value.simple);
}

test "decode refuses lengths the input cannot hold" {
    // An array of 2^32 items, and a text string of 2^64 - 1 bytes.
    try expectDecodeError([]const u64, "9b0000000100000000", error.EndOfInput);
    try expectDecodeError([]const u8, "7bffffffffffffffff", error.EndOfInput);
    const huge = "\x9b\x00\x00\x00\x01\x00\x00\x00\x00";
    try std.testing.expectError(error.EndOfInput, decodeValue(huge));
}

test "decode bounds nesting" {
    // Arrays of one array, one level more than allowed below the top item.
    const deep: [max_depth + 3]u8 = @splat(0x81);
    try std.testing.expectError(error.TooDeep, decode(Encoded, std.testing.allocator, &deep));
    try std.testing.expectError(error.TooDeep, decodeValue(&deep));
}

test "keyed structs leave out nulls and evolve" {
    const V1 = struct {
        at: u64,
        amount: i64,
        pub const cbor_keys = .{ .at = 0, .amount = 1 };
    };
    const V2 = struct {
        at: u64,
        amount: i64,
        memo: ?[]const u8 = null,
        fee: u64 = 10,
        pub const cbor_keys = .{ .at = 0, .amount = 1, .memo = 2, .fee = 3 };
    };

    const old = try encodeAlloc(std.testing.allocator, V1{ .at = 7, .amount = -5 });
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x00, 0x07, 0x01, 0x24 }, old);

    // A newer reader fills in what the old writer did not know.
    const up = try decode(V2, std.testing.allocator, old);
    try std.testing.expectEqualDeep(V2{ .at = 7, .amount = -5, .memo = null, .fee = 10 }, up);

    // An older reader skips what it does not know.
    const v2: V2 = .{ .at = 7, .amount = -5, .memo = "hi", .fee = 1 };
    const new = try encodeAlloc(std.testing.allocator, v2);
    defer std.testing.allocator.free(new);
    const down = try decode(V1, std.testing.allocator, new);
    try std.testing.expectEqualDeep(V1{ .at = 7, .amount = -5 }, down);
}

test "named structs round-trip" {
    const Kind = enum { credit, debit };
    const Entry = struct { kind: Kind, amount: u128, note: ?[]const u8, ratio: f32 };
    const in: Entry = .{ .kind = .debit, .amount = 1 << 100, .note = null, .ratio = 0.5 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try encodeAlloc(arena.allocator(), in);
    try std.testing.expectEqualDeep(in, try decode(Entry, arena.allocator(), bytes));
}

test "encode uint" {
    var buf: [16]u8 = undefined;
    const result = encode(&buf, @as(u64, 42));
    try std.testing.expectEqualSlices(u8, &.{ 0x18, 42 }, result);
}

test "encode text string" {
    var buf: [16]u8 = undefined;
    const result = encode(&buf, @as([]const u8, "hello"));
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 'h', 'e', 'l', 'l', 'o' }, result);
}

test "encode byte string" {
    var buf: [16]u8 = undefined;
    const result = encode(&buf, ByteString.from(&.{ 0xDE, 0xAD }));
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0xDE, 0xAD }, result);
}

test "encode struct as map" {
    var buf: [64]u8 = undefined;
    const result = encode(&buf, .{
        .name = @as([]const u8, "Alice"),
        .age = @as(u64, 30),
    });
    // map(2), text("name"), text("Alice"), text("age"), uint(30)
    try std.testing.expectEqualSlices(u8, &.{
        0xa2,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x65,
        'A',
        'l',
        'i',
        'c',
        'e',
        0x63,
        'a',
        'g',
        'e',
        0x18,
        30,
    }, result);
}

test "decode map and lookup" {
    const data = [_]u8{
        0xa2,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x65,
        'A',
        'l',
        'i',
        'c',
        'e',
        0x63,
        'a',
        'g',
        'e',
        0x18,
        30,
    };
    const result = try decodeValue(&data);
    switch (result.value) {
        .map => |content| {
            const name = (try mapLookup(content, "name")).?;
            try std.testing.expectEqualSlices(u8, "Alice", name.text);
            const age = (try mapLookup(content, "age")).?;
            try std.testing.expectEqual(@as(u64, 30), age.uint);
        },
        else => return error.UnexpectedType,
    }
}

test "decode byte string" {
    const data = [_]u8{ 0x42, 0xDE, 0xAD };
    const result = try decodeValue(&data);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD }, result.value.bytes);
}

test "decode array" {
    const data = [_]u8{
        0x83, // array(3)
        0x01,
        0x02,
        0x03,
    };
    const result = try decodeValue(&data);
    switch (result.value) {
        .array => |content| {
            const v1 = try decodeValue(content);
            try std.testing.expectEqual(@as(u64, 1), v1.value.uint);
            const v2 = try decodeValue(v1.rest);
            try std.testing.expectEqual(@as(u64, 2), v2.value.uint);
            const v3 = try decodeValue(v2.rest);
            try std.testing.expectEqual(@as(u64, 3), v3.value.uint);
        },
        else => return error.UnexpectedType,
    }
}
