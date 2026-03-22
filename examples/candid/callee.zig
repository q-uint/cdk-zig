const cdk = @import("cdk");
const candid = cdk.candid;

const Greeting = struct {
    greeting: []const u8,
};

fn greet() void {
    const name = candid.decode([]const u8, cdk.allocator, cdk.argData()) catch
        @panic("failed to decode args");
    const msg = std.fmt.allocPrint(cdk.allocator, "hello, {s}!", .{name}) catch
        @panic("failed to format greeting");
    const reply = candid.encode(cdk.allocator, .{Greeting{ .greeting = msg }}) catch
        @panic("failed to encode reply");
    cdk.replyRaw(reply);
}

const std = @import("std");

comptime {
    cdk.query(greet, "greet");
}
