// Shared test utilities for candid conformance tests.

const std = @import("std");
pub const testing = std.testing;
pub const candid = @import("../candid.zig");
pub const decode = candid.decode;
pub const decodeMany = candid.decodeMany;
pub const encode = candid.encode;
pub const Principal = candid.Principal;
pub const Blob = candid.Blob;
pub const Reserved = candid.Reserved;
pub const Empty = candid.Empty;
pub const RecursiveOpt = candid.RecursiveOpt;
pub const Func = candid.Func;
pub const QueryFunc = candid.QueryFunc;
pub const OnewayFunc = candid.OnewayFunc;
pub const CompositeQueryFunc = candid.CompositeQueryFunc;
pub const Service = candid.Service;

// Parse upstream test vector strings like "DIDL\00\01\7f" into byte arrays.
// Handles \xx hex escapes and literal ASCII characters.
pub fn x(comptime input: []const u8) []const u8 {
    return comptime blk: {
        var buf: [parseLen(input)]u8 = undefined;
        var i: usize = 0;
        var o: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\') {
                buf[o] = (hexVal(input[i + 1]) << 4) | hexVal(input[i + 2]);
                i += 3;
            } else {
                buf[o] = input[i];
                i += 1;
            }
            o += 1;
        }
        const final = buf;
        break :blk &final;
    };
}

fn parseLen(comptime input: []const u8) usize {
    var i: usize = 0;
    var len: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\') {
            i += 3;
        } else {
            i += 1;
        }
        len += 1;
    }
    return len;
}

fn hexVal(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}

pub fn expectDecodeError(comptime T: type, expected: anyerror, bytes: []const u8) !void {
    try testing.expectError(expected, decode(T, testing.allocator, bytes));
}

pub fn expectDecodeManyError(comptime T: type, expected: anyerror, bytes: []const u8) !void {
    try testing.expectError(expected, decodeMany(T, testing.allocator, bytes));
}

pub fn freeOptFunc(val: ?Func) void {
    if (val) |v| {
        testing.allocator.free(v.service.bytes);
        testing.allocator.free(v.method);
    }
}

pub fn expectSubtype(bytes: []const u8) !void {
    const val = try decode(?Func, testing.allocator, bytes);
    defer freeOptFunc(val);
    try testing.expect(val != null);
}

pub fn expectNotSubtype(bytes: []const u8) !void {
    const val = try decode(?Func, testing.allocator, bytes);
    defer freeOptFunc(val);
    try testing.expect(val == null);
}
