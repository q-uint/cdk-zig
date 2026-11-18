//! Instrumentation and deliberately broken flows, for the tests. Not an
//! example of anything. caller.zig is the example.

const cdk = @import("cdk");

const caller = @import("caller.zig");

// The wasm allocator does no tracking at all: no leak accounting, no
// poisoning of freed memory, which is why a dangling slice reads as plausible
// data rather than crashing. caller.zig swaps in a tracking one so this can
// see what it hides.
fn outstanding_bytes() u64 {
    return caller.tracking.total_requested_bytes;
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

// These flows only ever reject, so they reply with nothing.
const Probe = cdk.Transition(void);

fn unreachableReply(_: Held, _: []const u8) Probe {
    return .reject("the second call was supposed to fail");
}

// Names a method that does not exist, so the reject path runs holding
// pending state.
fn rejectingSecondCall(data: []const u8) Probe {
    const callee = caller.callee_principal orelse
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
    const callee = caller.callee_principal orelse
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
    const callee = caller.callee_principal orelse
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
    const callee = caller.callee_principal orelse
        return .reject("callee principal not set, pass it as init arg");
    return .commit(
        .{ .onReply = trappingSecondCall },
        .{ .callee = callee, .method = "greet" },
    );
}

// A comptime-known callee has no runtime address, so its bytes must land
// somewhere ic0.call_new can point. Not management_canister, which is empty
// and needs no address. This canister does not exist, so the reject it earns
// proves the bytes arrived.
const absent = cdk.principal.comptimeFromText("tz2ag-zx777-77776-aaabq-cai");

fn noSuchCanister(_: []const u8) Probe {
    return .reject("that canister was supposed to be absent");
}

fn call_comptime_callee() Probe {
    return .commit(
        .{ .onReply = noSuchCanister },
        .{ .callee = absent, .method = "greet" },
    );
}

comptime {
    cdk.update(call_comptime_callee, "call_comptime_callee");
    cdk.update(call_chained_rejecting, "call_chained_rejecting");
    cdk.update(call_chained_trapping, "call_chained_trapping");
    cdk.query(released_count, "greetings_freed");
    cdk.query(outstanding_bytes, "outstanding_bytes");
}
