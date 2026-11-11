const std = @import("std");
const cdk = @import("cdk");
const tr = cdk.transition;

pub const cdk_codec = cdk.CandidCodec;

const Greeting = struct {
    greeting: []const u8,
};

fn greet(name: []const u8) tr.Transition {
    const msg = std.fmt.allocPrint(cdk.allocator, "hello, {s}!", .{name}) catch
        @panic("failed to format greeting");
    return tr.reply(Greeting{ .greeting = msg });
}

comptime {
    cdk.query(greet, "greet");
}
