//! Instrumented calls and deliberately broken flows, for test.zig.

const std = @import("std");
const cdk = @import("cdk");

// The wasm allocator keeps no accounts, so a leak or a dangling slice goes
// unseen. This one counts every byte handed out.
var tracking: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{
    .backing_allocator = std.heap.wasm_allocator,
};

pub const cdk_allocator = tracking.allocator();

// Every allocated byte is counted, so a kept scratch buffer would read as a
// leak.
pub const cdk_options = struct {
    pub const scratch_retain: usize = 0;
};

var callee_principal: ?cdk.principal.Principal = null;

fn init(arg: []const u8) void {
    if (arg.len == 0) return;
    callee_principal = cdk.principal.Principal.tryFrom(arg) catch
        @panic("invalid principal");
}

fn outstanding_bytes() u64 {
    return tracking.total_requested_bytes;
}

// Counts the paths that are otherwise invisible: a rejected second call, and
// a continuation that traps.
var released: u32 = 0;

fn released_count() u32 {
    return released;
}

const Held = struct {
    text: []const u8,

    fn deinit(self: Held) void {
        cdk.persistent.free(self.text);
        released += 1;
    }
};

fn chainedFarewellReplied(
    scratch: std.mem.Allocator,
    held: Held,
    data: []const u8,
) cdk.Transition([]const u8) {
    const combined = std.mem.concat(scratch, u8, &.{ held.text, " and ", data }) catch
        return .reject("out of memory");
    return .reply(combined);
}

fn chainedGreetReplied(data: []const u8) cdk.Transition([]const u8) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    const kept = cdk.persistent.dupe(u8, data) catch return .reject("out of memory");
    return .commit(.{
        .onReply = chainedFarewellReplied,
        .onFinish = Held.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Held{ .text = kept },
    });
}

fn call_chained() cdk.Transition([]const u8) {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = chainedGreetReplied },
        .{ .callee = callee, .method = "greet" },
    );
}

// The flows below only ever reject, so they reply with nothing.
const Probe = cdk.Transition(void);

fn unreachableReply(_: Held, _: []const u8) Probe {
    return .reject("the second call was supposed to fail");
}

// Names a method that does not exist, so the reject path runs holding
// pending state.
fn rejectingSecondCall(data: []const u8) Probe {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    const kept = cdk.persistent.dupe(u8, data) catch return .reject("out of memory");
    return .commit(.{
        .onReply = unreachableReply,
        .onFinish = Held.deinit,
    }, .{
        .callee = callee,
        .method = "no_such_method",
        .pending = Held{ .text = kept },
    });
}

fn call_chained_rejecting() Probe {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = rejectingSecondCall },
        .{ .callee = callee, .method = "greet" },
    );
}

// Traps, so neither handler completes and only the cleanup callback is left
// to release the pending state.
fn trappingReply(_: Held, _: []const u8) Probe {
    cdk.trap("trapping on purpose");
}

fn trappingSecondCall(data: []const u8) Probe {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    const kept = cdk.persistent.dupe(u8, data) catch return .reject("out of memory");
    return .commit(.{
        .onReply = trappingReply,
        .onFinish = Held.deinit,
    }, .{
        .callee = callee,
        .method = "farewell",
        .pending = Held{ .text = kept },
    });
}

fn call_chained_trapping() Probe {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = trappingSecondCall },
        .{ .callee = callee, .method = "greet" },
    );
}

// A comptime-known callee has no runtime address, so its bytes must land
// somewhere ic0.call_new can point. Not management_canister, which is empty
// and needs no address. The last id is in no subnet's range, so the reject it
// earns proves the bytes arrived.
const absent = cdk.principal.canisterId(std.math.maxInt(u64));

fn noSuchCanister(_: []const u8) Probe {
    return .reject("that canister was supposed to be absent");
}

fn call_comptime_callee() Probe {
    return .commit(
        .{ .onReply = noSuchCanister },
        .{ .callee = absent, .method = "greet" },
    );
}

// greet replies with text, so a continuation expecting a u64 cannot decode
// it. Both calls hold pending state, to show it is released either way.
fn numberReply(_: Held, _: u64) Probe {
    return .reject("the reply was supposed to be undecodable");
}

// Rejects with the raw reply, proving the bytes arrived.
fn keptUndecodable(_: Held, reply: cdk.Undecodable) Probe {
    return .reject(reply.bytes);
}

fn undecodableCall(comptime handled: bool) Probe {
    const callee = callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    const kept = cdk.persistent.dupe(u8, "pending") catch return .reject("out of memory");
    const spec = if (handled) .{
        .onReply = numberReply,
        .onUndecodable = keptUndecodable,
        .onFinish = Held.deinit,
    } else .{
        .onReply = numberReply,
        .onFinish = Held.deinit,
    };
    return .commit(spec, .{
        .callee = callee,
        .method = "greet",
        .pending = Held{ .text = kept },
    });
}

fn call_undecodable_handled() Probe {
    return undecodableCall(true);
}

fn call_undecodable_trapping() Probe {
    return undecodableCall(false);
}

comptime {
    cdk.init(init);
    cdk.update(call_chained, "call_chained");
    cdk.update(call_undecodable_handled, "call_undecodable_handled");
    cdk.update(call_undecodable_trapping, "call_undecodable_trapping");
    cdk.update(call_comptime_callee, "call_comptime_callee");
    cdk.update(call_chained_rejecting, "call_chained_rejecting");
    cdk.update(call_chained_trapping, "call_chained_trapping");
    cdk.query(released_count, "greetings_freed");
    cdk.query(outstanding_bytes, "outstanding_bytes");
}
