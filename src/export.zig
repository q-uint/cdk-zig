const codec = @import("codec.zig");
const ic0 = @import("ic0.zig");
const profiling = @import("profiling.zig");
const transition = @import("transition.zig");

fn entryPoint(comptime func: anytype, comptime context: ic0.Context) fn () void {
    return transition.entryPoint(func, context, codec.default);
}

pub fn init(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .I), "canister_init")), .{ .name = "canister_init" });
}

pub fn query(comptime func: anytype, name: []const u8) void {
    queryWith(codec.default, func, name);
}

pub fn update(comptime func: anytype, name: []const u8) void {
    updateWith(codec.default, func, name);
}

/// A query whose argument and reply use `Codec` rather than `cdk_codec`.
pub fn queryWith(comptime Codec: type, comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .RQ, Codec), name)), .{ .name = "canister_query " ++ name });
    // A query's trace is rolled back with the rest of its state, so profiling
    // builds export it again as an update that keeps it.
    if (profiling.enabled) {
        const traced = profiling.traced(transition.entryPoint(func, .U, Codec), name);
        @export(&callConvWrapper(traced), .{
            .name = "canister_update " ++ profiling.query_prefix ++ name,
        });
    }
}

/// An update whose argument and reply use `Codec` rather than `cdk_codec`.
pub fn updateWith(comptime Codec: type, comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .U, Codec), name)), .{ .name = "canister_update " ++ name });
}

pub fn preUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .G), "canister_pre_upgrade")), .{ .name = "canister_pre_upgrade" });
}

pub fn postUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .I), "canister_post_upgrade")), .{ .name = "canister_post_upgrade" });
}

pub fn heartbeat(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .T), "canister_heartbeat")), .{ .name = "canister_heartbeat" });
}

pub fn inspectMessage(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .F), "canister_inspect_message")), .{ .name = "canister_inspect_message" });
}

pub fn globalTimer(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .T), "canister_global_timer")), .{ .name = "canister_global_timer" });
}

pub fn onLowWasmMemory(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(entryPoint(func, .T), "canister_on_low_wasm_memory")), .{ .name = "canister_on_low_wasm_memory" });
}

// The profiling endpoints speak Raw whatever cdk_codec the canister declares,
// so the flamegraph tooling can read any canister.
fn rawQuery(comptime func: anytype, comptime name: []const u8) void {
    @export(&callConvWrapper(transition.entryPoint(func, .RQ, codec.Raw)), .{ .name = "canister_query " ++ name });
}

fn rawUpdate(comptime func: anytype, comptime name: []const u8) void {
    @export(&callConvWrapper(transition.entryPoint(func, .U, codec.Raw)), .{ .name = "canister_update " ++ name });
}

comptime {
    if (profiling.enabled) {
        rawQuery(profiling.getInstructions, "__get_instructions");
        rawQuery(profiling.getProfiling, "__get_profiling");
        rawQuery(profiling.getProfilingNames, "__get_profiling_names");
        rawUpdate(profiling.setProfiling, "__set_profiling");
        rawUpdate(profiling.toggleTracing, "__toggle_tracing");
        rawUpdate(profiling.toggleEntry, "__toggle_entry");
    }
}

fn callConvWrapper(comptime func: fn () void) fn () callconv(.c) void {
    return struct {
        fn f() callconv(.c) void {
            func();
        }
    }.f;
}
