//! JSON on the wire, by way of std.json. Anything with these two functions is
//! a codec. Both allocate from `a`, which the caller frees in one go: the CDK
//! when the message ends, the test client when the reply is released.

const std = @import("std");

pub fn encode(a: std.mem.Allocator, comptime T: type, value: T) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

pub fn decode(a: std.mem.Allocator, comptime T: type, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, bytes, .{});
}
