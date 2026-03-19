const cdk = @import("cdk");
const CallFuture = cdk.call.CallFuture;

var callee_principal: ?[]const u8 = null;

fn init() void {
    const arg = cdk.argData();
    if (arg.len == 0) return;
    callee_principal = cdk.principal.decode(arg) catch
        @panic("invalid principal");
}

fn call_greet() void {
    const callee = callee_principal orelse {
        cdk.trap("callee principal not set; pass it as init arg");
        return;
    };
    const future = CallFuture.call(callee, "greet", "") catch {
        cdk.trap("call_perform failed");
        return;
    };

    future.onReply(struct {
        fn f(result: CallFuture.Result) void {
            switch (result) {
                .reply => |data| cdk.replyRaw(data),
                .reject => |r| cdk.trap(r.message),
            }
        }
    }.f);
}

fn greet() void {
    cdk.replyRaw("hello from caller");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.query(greet, "greet");
}
