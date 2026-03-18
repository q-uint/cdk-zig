const cdk = @import("cdk");
const ic0 = cdk.ic0;
const CallFuture = cdk.call.CallFuture;

var callee_principal: ?[]const u8 = null;

fn init() callconv(.c) void {
    const arg = cdk.arg_data();
    if (arg.len == 0) return;
    callee_principal = cdk.principal.decode(arg) catch
        @panic("invalid principal");
}

fn call_greet() callconv(.c) void {
    const callee = callee_principal orelse {
        cdk.trap("callee principal not set; pass it as init arg");
        return;
    };
    const future = CallFuture.call(callee, "greet", "") catch {
        cdk.trap("call_perform failed");
        return;
    };

    future.on_reply(struct {
        fn f(result: cdk.call.CallResult) void {
            switch (result) {
                .reply => |data| cdk.reply_raw(data),
                .reject => |r| cdk.trap(r.message),
            }
        }
    }.f);
}

fn greet() callconv(.c) void {
    cdk.reply_raw("hello from caller");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.query(greet, "greet");
}
