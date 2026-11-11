const root = @import("root");
const ic0 = @import("ic0.zig");
const ic0_spec = @import("ic0_spec.zig");
const profiling = @import("profiling.zig");
const transition = @import("transition.zig");

const allocator = @import("allocator.zig").default;

/// Wire format for entry point arguments. Declare `cdk_codec` in your root
/// source file to use something other than raw bytes:
///
///     pub const cdk_codec = cdk.CandidCodec;
pub const codec = if (@hasDecl(root, "cdk_codec")) root.cdk_codec else transition.Raw;

pub fn init(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .I), "canister_init")), .{ .name = "canister_init" });
}

pub fn query(comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .RQ), name)), .{ .name = "canister_query " ++ name });
}

pub fn update(comptime func: anytype, name: []const u8) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .U), name)), .{ .name = "canister_update " ++ name });
}

pub fn preUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .G), "canister_pre_upgrade")), .{ .name = "canister_pre_upgrade" });
}

pub fn postUpgrade(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .I), "canister_post_upgrade")), .{ .name = "canister_post_upgrade" });
}

pub fn heartbeat(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .T), "canister_heartbeat")), .{ .name = "canister_heartbeat" });
}

pub fn inspectMessage(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .F), "canister_inspect_message")), .{ .name = "canister_inspect_message" });
}

pub fn globalTimer(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .T), "canister_global_timer")), .{ .name = "canister_global_timer" });
}

pub fn onLowWasmMemory(comptime func: anytype) void {
    @export(&callConvWrapper(profiling.traced(normalize(func, .T), "canister_on_low_wasm_memory")), .{ .name = "canister_on_low_wasm_memory" });
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

// An entry point may take the decoded message argument, and may return a
// Transition stating how the message ended. The system API wants neither, so
// both are handled here.
fn normalize(comptime func: anytype, comptime context: ic0_spec.Context) fn () void {
    const info = @typeInfo(@TypeOf(func)).@"fn";

    if (info.param_types.len == 0) {
        if (info.return_type == void) return func;
        return struct {
            fn f() void {
                _ = func();
            }
        }.f;
    }

    if (info.param_types.len != 1)
        @compileError("an entry point takes at most one parameter, the decoded argument");

    // Reading the argument means calling msg_arg_data, which the spec does
    // not permit from every entry point. A pre_upgrade or timer handler has
    // no argument to read and would trap at runtime.
    if (!ic0_spec.allows("msg_arg_data_size", context))
        @compileError("this entry point runs in a context with no message argument, " ++
            "so its handler cannot take one");

    const Arg = info.param_types[0] orelse
        @compileError("an entry point may not take a generic parameter");

    return struct {
        fn f() void {
            const size: usize = @intCast(ic0.msg_arg_data_size());
            const data = allocator.alloc(u8, size) catch
                @panic("failed to allocate argument data");
            defer allocator.free(data);
            if (size > 0) ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));
            _ = func(codec.decode(Arg, data));
        }
    }.f;
}

fn callConvWrapper(comptime func: fn () void) fn () callconv(.c) void {
    return struct {
        fn f() callconv(.c) void {
            func();
        }
    }.f;
}
