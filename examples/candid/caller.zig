const cdk = @import("cdk");
const candid = cdk.candid;
const CallFuture = cdk.call.CallFuture;

var callee_principal: ?[]const u8 = null;

fn init() void {
    const arg = cdk.argData();
    if (arg.len == 0) return;
    callee_principal = cdk.principal.decode(arg) catch
        @panic("invalid principal");
}

const Greeting = struct {
    greeting: []const u8,
};

fn call_greet() void {
    const callee = callee_principal orelse {
        cdk.trap("callee principal not set; pass it as init arg");
        return;
    };
    const arg = candid.encode(cdk.allocator, .{@as([]const u8, "world")}) catch
        @panic("failed to encode args");
    const future = CallFuture.call(callee, "greet", arg) catch {
        cdk.trap("call_perform failed");
        return;
    };

    future.onReply(struct {
        fn f(result: CallFuture.Result) void {
            switch (result) {
                .reply => |data| {
                    const g = candid.decode(Greeting, cdk.allocator, data) catch
                        @panic("failed to decode reply");
                    const reply = candid.encode(cdk.allocator, .{g}) catch
                        @panic("failed to encode reply");
                    cdk.replyRaw(reply);
                },
                .reject => |r| cdk.trap(r.message),
            }
        }
    }.f);
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
}
