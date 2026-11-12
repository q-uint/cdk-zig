const cdk = @import("cdk");
const candid = cdk.candid;
const tr = cdk.transition;

pub const cdk_codec = cdk.CandidCodec;

var callee_principal: ?cdk.principal.Principal = null;

fn init(callee: cdk.principal.Principal) void {
    callee_principal = callee;
}

const Greeting = struct {
    greeting: []const u8,
};

fn greetReplied(greeting: Greeting) tr.Transition {
    const reply = candid.encode(cdk.allocator, .{greeting}) catch
        @panic("failed to encode reply");
    return tr.replyRaw(reply);
}

fn call_greet() tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(.{ .onReply = greetReplied }, .{
        .callee = callee,
        .method = "greet",
        .arg = @as([]const u8, "world"),
    }) catch tr.reject("call_perform failed");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
}
