const cdk = @import("cdk");

pub const cdk_codec = cdk.CandidCodec;

var callee_principal: ?cdk.principal.Principal = null;

fn init(callee: cdk.principal.Principal) void {
    callee_principal = callee;
}

const Greeting = struct {
    greeting: []const u8,
};

fn greetReplied(greeting: Greeting) cdk.Transition(Greeting) {
    return .reply(greeting);
}

fn call_greet() cdk.Transition(Greeting) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(.{ .onReply = greetReplied }, .{
        .callee = callee,
        .method = "greet",
        .arg = @as([]const u8, "world"),
    });
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
}
