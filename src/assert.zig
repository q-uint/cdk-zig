//! `std.debug.assert` is `if (!ok) unreachable`, and `unreachable` is
//! undefined behaviour in ReleaseFast and ReleaseSmall. Canisters are built
//! ReleaseSmall, so every std assertion is UB in a shipped canister rather
//! than a trap. These always hold, in every build mode, and carry a message.

const builtin = @import("builtin");
const ic0 = @import("ic0.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub fn assert(ok: bool, comptime message: []const u8) void {
    if (ok) return;
    fail("assertion failed: " ++ message);
}

fn fail(comptime message: []const u8) noreturn {
    if (comptime is_wasm) {
        ic0.trap(message.ptr, @intCast(message.len));
        unreachable;
    }
    @panic(message);
}
