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

// Two calls in sequence. The second is sent from the first one's
// continuation, so this canister is three separate message executions, not
// one function that waits twice.
//
// The greeting has to survive from the first continuation to the second, and
// nothing is carried across a commit, so it goes in a global. That global is
// the bug: two callers interleaving would overwrite each other's greeting.
var greeting: ?[]const u8 = null;

fn chainedGreetReplied(data: []const u8) tr.Transition {
    // Copied, because the reply buffer is freed when this continuation
    // returns. Keeping the slice would leave a dangling pointer that the
    // next callback's allocation reuses.
    greeting = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");

    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = chainedFarewellReplied },
        .{ .callee = callee, .method = "farewell" },
    ) catch tr.reject("call_perform failed");
}

fn chainedFarewellReplied(data: []const u8) tr.Transition {
    const first = greeting orelse return tr.reject("lost the greeting");
    defer cdk.allocator.free(first);
    greeting = null;

    const separator = " and ";
    const combined = cdk.allocator.alloc(u8, first.len + separator.len + data.len) catch
        return tr.reject("out of memory");
    @memcpy(combined[0..first.len], first);
    @memcpy(combined[first.len..][0..separator.len], separator);
    @memcpy(combined[first.len + separator.len ..][0..data.len], data);
    return tr.replyRaw(combined);
}

fn call_chained() tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = chainedGreetReplied },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.update(call_chained, "call_chained");
    cdk.query(greet, "greet");
}
