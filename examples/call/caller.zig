const std = @import("std");
const cdk = @import("cdk");

// Used by probe.zig, which reads it to spot leaks. cdk_allocator has to be
// declared in the root source file, so it lives here rather than there.
pub var tracking: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{
    .backing_allocator = std.heap.wasm_allocator,
};

pub const cdk_allocator = tracking.allocator();

pub var callee_principal: ?cdk.principal.Principal = null;

fn init(arg: []const u8) void {
    if (arg.len == 0) return;
    callee_principal = cdk.principal.Principal.tryFrom(arg) catch
        @panic("invalid principal");
}

fn greetReplied(data: []const u8) cdk.Transition([]const u8) {
    return .reply(data);
}

fn call_greet() cdk.Transition([]const u8) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = greetReplied },
        .{ .callee = callee, .method = "greet" },
    );
}

fn greet() []const u8 {
    return "hello from caller";
}

// Passed to commit as .onFinish, which the CDK runs on whichever of reply,
// reject or cleanup happens, so no path leaks the text.
const Greeting = struct {
    text: []const u8,

    fn deinit(self: Greeting) void {
        cdk.persistent.free(self.text);
    }
};

// Two calls in sequence. The second is sent from the first one's
// continuation, so this canister is three separate message executions, not
// one function that waits twice.
//
// The greeting reaches the second continuation as pending state, held per
// call rather than in a global, so two callers cannot overwrite each other.
fn chainedGreetReplied(data: []const u8) cdk.Transition([]const u8) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");

    // Copied to persistent memory, because the reply buffer is freed when
    // this continuation returns.
    const kept = cdk.persistent.dupe(u8, data) catch return .reject("out of memory");

    // If the call is never sent, the CDK finishes the pending state itself,
    // so the copy above is not leaked.
    return .commit(.{
        .onReply = chainedFarewellReplied,
        .onFinish = Greeting.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Greeting{ .text = kept },
    });
}

fn chainedFarewellReplied(
    scratch: std.mem.Allocator,
    greeting: Greeting,
    data: []const u8,
) cdk.Transition([]const u8) {
    const combined = std.mem.concat(scratch, u8, &.{ greeting.text, " and ", data }) catch
        return .reject("out of memory");
    return .reply(combined);
}

fn call_chained() cdk.Transition([]const u8) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = chainedGreetReplied },
        .{ .callee = callee, .method = "greet" },
    );
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.update(call_chained, "call_chained");
    cdk.query(greet, "greet");

    _ = @import("probe.zig");
}
