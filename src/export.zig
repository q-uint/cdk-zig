pub fn init(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_init" });
}

pub fn query(comptime func: fn () void, name: []const u8) void {
    @export(&wrapper(func), .{ .name = "canister_query " ++ name });
}

pub fn update(comptime func: fn () void, name: []const u8) void {
    @export(&wrapper(func), .{ .name = "canister_update " ++ name });
}

pub fn preUpgrade(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_pre_upgrade" });
}

pub fn postUpgrade(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_post_upgrade" });
}

pub fn heartbeat(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_heartbeat" });
}

pub fn inspectMessage(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_inspect_message" });
}

pub fn globalTimer(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_global_timer" });
}

pub fn onLowWasmMemory(comptime func: fn () void) void {
    @export(&wrapper(func), .{ .name = "canister_on_low_wasm_memory" });
}

fn wrapper(comptime func: fn () void) fn () callconv(.c) void {
    return struct {
        fn f() callconv(.c) void {
            func();
        }
    }.f;
}
