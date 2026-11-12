const profiling = @import("profiling.zig");
const transition = @import("transition.zig");

pub fn init(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .I), "canister_init")), .{ .name = "canister_init" });
}

pub fn query(comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .RQ), name)), .{ .name = "canister_query " ++ name });
}

pub fn update(comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .U), name)), .{ .name = "canister_update " ++ name });
}

pub fn preUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .G), "canister_pre_upgrade")), .{ .name = "canister_pre_upgrade" });
}

pub fn postUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .I), "canister_post_upgrade")), .{ .name = "canister_post_upgrade" });
}

pub fn heartbeat(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .T), "canister_heartbeat")), .{ .name = "canister_heartbeat" });
}

pub fn inspectMessage(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .F), "canister_inspect_message")), .{ .name = "canister_inspect_message" });
}

pub fn globalTimer(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .T), "canister_global_timer")), .{ .name = "canister_global_timer" });
}

pub fn onLowWasmMemory(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(transition.entryPoint(func, .T), "canister_on_low_wasm_memory")), .{ .name = "canister_on_low_wasm_memory" });
}

comptime {
    if (profiling.enabled) {
        query(profiling.getCyclesHandler, "__get_cycles");
        query(profiling.getProfilingHandler, "__get_profiling");
        query(profiling.getProfilingNamesHandler, "__get_profiling_names");
        update(profiling.toggleTracingHandler, "__toggle_tracing");
        update(profiling.toggleEntryHandler, "__toggle_entry");
    }
}

fn callConvWrapper(comptime func: fn () void) fn () callconv(.c) void {
    return struct {
        fn f() callconv(.c) void {
            func();
        }
    }.f;
}
