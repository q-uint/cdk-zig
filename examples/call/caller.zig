const std = @import("std");
const cdk = @import("cdk");
const tr = cdk.transition;

// Tracks outstanding bytes so the tests can see leaks the wasm allocator
// would otherwise hide. It does no tracking at all: no leak accounting, no
// poisoning of freed memory, which is why a dangling slice here reads as
// plausible data rather than crashing.
var tracking: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{
    .backing_allocator = std.heap.wasm_allocator,
};

pub const cdk_allocator = tracking.allocator();

fn outstanding_bytes() void {
    const total: u64 = tracking.total_requested_bytes;
    cdk.replyRaw(std.mem.asBytes(&total));
}

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

// Passed to commit as .onFinish, which the CDK runs on whichever of reply,
// reject or cleanup happens, so no path leaks the text.
//
// Counted so the tests can check the paths that are otherwise invisible: a
// rejected second call, and a continuation that traps.
var greetings_freed: u32 = 0;

const Greeting = struct {
    text: []const u8,

    fn deinit(self: Greeting) void {
        cdk.allocator.free(self.text);
        greetings_freed += 1;
    }
};

fn greetings_freed_count() void {
    cdk.replyRaw(std.mem.asBytes(&greetings_freed));
}

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

// The second call names a method that does not exist, so the reject path
// runs with pending state held.
fn rejectedSecondCall(data: []const u8) tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    const kept = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");
    return tr.commit(.{
        .onReply = chainedFarewellReplied,
        .onFinish = Greeting.deinit,
    }, .{
        .callee = callee,
        .method = "no_such_method",
        .pending = Greeting{ .text = kept },
    }) catch tr.reject("call_perform failed");
}

fn call_chained_rejecting() tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = rejectedSecondCall },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

// The continuation traps, so neither handler completes and only the cleanup
// callback can release the pending state.
fn trappingContinuation(_: Greeting, _: []const u8) tr.Transition {
    cdk.trap("trapping on purpose");
}

fn trappingSecondCall(data: []const u8) tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    const kept = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");
    return tr.commit(.{
        .onReply = trappingContinuation,
        .onFinish = Greeting.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Greeting{ .text = kept },
    }) catch tr.reject("call_perform failed");
}

fn call_chained_trapping() tr.Transition {
    const callee = callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = trappingSecondCall },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

comptime {
    cdk.init(init);
    cdk.update(call_greet, "call_greet");
    cdk.update(call_chained, "call_chained");
    cdk.update(call_chained_rejecting, "call_chained_rejecting");
    cdk.update(call_chained_trapping, "call_chained_trapping");
    cdk.query(greetings_freed_count, "greetings_freed");
    cdk.query(outstanding_bytes, "outstanding_bytes");
    cdk.query(greet, "greet");
}
