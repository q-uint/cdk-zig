const std = @import("std");
const cdk = @import("cdk");

pub const cdk_codec = cdk.CandidCodec;

const Greeting = struct {
    greeting: []const u8,
};

fn greet(scratch: std.mem.Allocator, name: []const u8) !Greeting {
    return .{ .greeting = try std.fmt.allocPrint(scratch, "hello, {s}!", .{name}) };
}

comptime {
    cdk.query(greet, "greet");
}
