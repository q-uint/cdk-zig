const std = @import("std");
const cdk = @import("cdk");
const tr = cdk.transition;

// Used by probe.zig, which reads it to spot leaks. cdk_allocator has to be
// declared in the root source file, so it lives here rather than there.
pub var tracking: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{
    .backing_allocator = std.heap.wasm_allocator,
};

pub const cdk_allocator = tracking.allocator();

pub var callee_principal: ?[]const u8 = null;

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

// Passed to commit as .onFinish, which the CDK runs on whichever of reply,
// reject or cleanup happens, so no path leaks the text.
const Greeting = struct {
    text: []const u8,

    fn deinit(self: Greeting) void {
        cdk.allocator.free(self.text);
    }
};

// Two calls in sequence. The second is sent from the first one's
// continuation, so this canister is three separate message executions, not
// one function that waits twice.
//
// The greeting reaches the second continuation as pending state, held per
// call rather than in a global, so two callers cannot overwrite each other.
fn chainedGreetReplied(data: []const u8) tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");

    // Copied, because the reply buffer is freed when this continuation
    // returns.
    const kept = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");

    return tr.commit(.{
        .onReply = chainedFarewellReplied,
        .onFinish = Greeting.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Greeting{ .text = kept },
    }) catch tr.reject("call_perform failed");
}

fn chainedFarewellReplied(greeting: Greeting, data: []const u8) tr.Transition {
    const first = greeting.text;
    const separator = " and ";
    const combined = cdk.allocator.alloc(u8, first.len + separator.len + data.len) catch
        return tr.reject("out of memory");
    defer cdk.allocator.free(combined);

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

    _ = @import("probe.zig");
}
