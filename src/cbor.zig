const std = @import("std");

pub const Error = error{
    EndOfInput,
    InvalidCbor,
    UnexpectedType,
    Overflow,
    OutOfMemory,
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
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isByteString(T)) return headSize(value.data.len) + value.data.len;
            var size = headSize(info.fields.len);
            inline for (info.fields) |f| {
                size += headSize(f.name.len) + f.name.len;
                size += encodedSize(@field(value, f.name));
            }
            return size;
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
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
        .int, .comptime_int => return headSize(@as(usize, @intCast(value))),
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
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
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isByteString(T)) {
                writeHead(buf, pos, MAJOR_BYTES, value.data.len);
                @memcpy(buf[pos.*..][0..value.data.len], value.data);
                pos.* += value.data.len;
                return;
            }
            writeHead(buf, pos, MAJOR_MAP, info.fields.len);
            inline for (info.fields) |f| {
                writeHead(buf, pos, MAJOR_TEXT, f.name.len);
                @memcpy(buf[pos.*..][0..f.name.len], f.name);
                pos.* += f.name.len;
                encodeInto(buf, pos, @field(value, f.name));
            }
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
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
        .int, .comptime_int => {
            writeHead(buf, pos, MAJOR_UINT, @intCast(value));
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
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
            const len: usize = @intCast(val);
            if (pos + len > data.len) return Error.EndOfInput;
            return .{ .value = .{ .bytes = data[pos .. pos + len] }, .rest = data[pos + len ..] };
        },
        MAJOR_TEXT => {
            const len: usize = @intCast(val);
            if (pos + len > data.len) return Error.EndOfInput;
            return .{ .value = .{ .text = data[pos .. pos + len] }, .rest = data[pos + len ..] };
        },
        MAJOR_ARRAY => {
            const count: usize = @intCast(val);
            const start = pos;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                pos += try skipValueAt(data[pos..]);
            }
            return .{ .value = .{ .array = data[start..pos] }, .rest = data[pos..] };
        },
        MAJOR_MAP => {
            const count: usize = @intCast(val);
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
        MAJOR_SIMPLE => return .{ .value = .{ .simple = @intCast(val) }, .rest = data[pos..] },
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

fn skipValueAt(data: []const u8) Error!usize {
    if (data.len == 0) return Error.EndOfInput;
    const initial = data[0];
    const major: u3 = @intCast(initial >> 5);
    const additional: u5 = @intCast(initial & 0x1f);
    var pos: usize = 1;

    const val = try readArgument(data, additional, &pos);

    switch (major) {
        MAJOR_UINT, MAJOR_NINT, MAJOR_SIMPLE => return pos,
        MAJOR_BYTES, MAJOR_TEXT => {
            const len: usize = @intCast(val);
            return pos + len;
        },
        MAJOR_ARRAY => {
            const count: usize = @intCast(val);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                pos += try skipValueAt(data[pos..]);
            }
            return pos;
        },
        MAJOR_MAP => {
            const count: usize = @intCast(val);
            var i: usize = 0;
            while (i < count * 2) : (i += 1) {
                pos += try skipValueAt(data[pos..]);
            }
            return pos;
        },
        MAJOR_TAG => {
            pos += try skipValueAt(data[pos..]);
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

// CBOR self-describe tag (55799)
pub fn withSelfDescribeTag(buf: []u8, inner: []const u8) []const u8 {
    buf[0] = 0xd9;
    buf[1] = 0xd9;
    buf[2] = 0xf7;
    @memcpy(buf[3..][0..inner.len], inner);
    return buf[0 .. 3 + inner.len];
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
