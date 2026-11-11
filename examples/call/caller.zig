const cdk = @import("cdk");
const tr = cdk.transition;

var callee_principal: ?[]const u8 = null;

fn init() void {
    const arg = cdk.argData();
    if (arg.len == 0) return;
    callee_principal = cdk.principal.decode(arg) catch
        @panic("invalid principal");
}

fn greetReplied(data: []const u8) tr.Transition {
    return tr.replyRaw(data);
}

fn call_greet() tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = greetReplied },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

fn greet() void {
    cdk.replyRaw("hello from caller");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.query(greet, "greet");
}
