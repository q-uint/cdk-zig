const std = @import("std");
const cdk = @import("cdk");

pub const cdk_codec = cdk.CandidCodec;

const Greeting = struct {
    greeting: []const u8,
};

fn greet(name: []const u8) Greeting {
    const msg = std.fmt.allocPrint(cdk.allocator, "hello, {s}!", .{name}) catch
        @panic("failed to format greeting");
    return .{ .greeting = msg };
}

comptime {
    cdk.query(greet, "greet");
}
