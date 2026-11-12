//! Instrumentation and deliberately broken flows, for the tests. Not an
//! example of anything. caller.zig is the example.

const std = @import("std");
const cdk = @import("cdk");
const tr = cdk.transition;

const caller = @import("caller.zig");

// The wasm allocator does no tracking at all: no leak accounting, no
// poisoning of freed memory, which is why a dangling slice reads as plausible
// data rather than crashing. caller.zig swaps in a tracking one so this can
// see what it hides.
fn outstanding_bytes() void {
    const total: u64 = caller.tracking.total_requested_bytes;
    cdk.replyRaw(std.mem.asBytes(&total));
}

// Counts the paths that are otherwise invisible: a rejected second call, and
// a continuation that traps.
var released: u32 = 0;

fn released_count() void {
    cdk.replyRaw(std.mem.asBytes(&released));
}

const Held = struct {
    text: []const u8,

    fn deinit(self: Held) void {
        cdk.allocator.free(self.text);
        released += 1;
    }
};

fn unreachableReply(_: Held, _: []const u8) tr.Transition {
    return tr.reject("the second call was supposed to fail");
}

// Names a method that does not exist, so the reject path runs holding
// pending state.
fn rejectingSecondCall(data: []const u8) tr.Transition {
    const callee = caller.callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    const kept = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");
    return tr.commit(.{
        .onReply = unreachableReply,
        .onFinish = Held.deinit,
    }, .{
        .callee = callee,
        .method = "no_such_method",
        .pending = Held{ .text = kept },
    }) catch tr.reject("call_perform failed");
}

fn call_chained_rejecting() tr.Transition {
    const callee = caller.callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = rejectingSecondCall },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

// Traps, so neither handler completes and only the cleanup callback is left
// to release the pending state.
fn trappingReply(_: Held, _: []const u8) tr.Transition {
    cdk.trap("trapping on purpose");
}

fn trappingSecondCall(data: []const u8) tr.Transition {
    const callee = caller.callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    const kept = cdk.allocator.dupe(u8, data) catch return tr.reject("out of memory");
    return tr.commit(.{
        .onReply = trappingReply,
        .onFinish = Held.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Held{ .text = kept },
    }) catch tr.reject("call_perform failed");
}

fn call_chained_trapping() tr.Transition {
    const callee = caller.callee_principal orelse
        return tr.reject("callee principal not set, pass it as init arg");
    return tr.commit(
        .{ .onReply = trappingSecondCall },
        .{ .callee = callee, .method = "greet" },
    ) catch tr.reject("call_perform failed");
}

comptime {
    cdk.update(call_chained_rejecting, "call_chained_rejecting");
    cdk.update(call_chained_trapping, "call_chained_trapping");
    cdk.query(released_count, "greetings_freed");
    cdk.query(outstanding_bytes, "outstanding_bytes");
}
