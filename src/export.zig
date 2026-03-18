pub fn init(func: anytype) void {
    @export(&func, .{ .name = "canister_init" });
}

pub fn query(func: anytype, name: []const u8) void {
    @export(&func, .{ .name = "canister_query " ++ name });
}

pub fn update(func: anytype, name: []const u8) void {
    @export(&func, .{ .name = "canister_update " ++ name });
}

pub fn preUpgrade(func: anytype) void {
    @export(&func, .{ .name = "canister_pre_upgrade" });
}

pub fn postUpgrade(func: anytype) void {
    @export(&func, .{ .name = "canister_post_upgrade" });
}

pub fn heartbeat(func: anytype) void {
    @export(&func, .{ .name = "canister_heartbeat" });
}

pub fn inspectMessage(func: anytype) void {
    @export(&func, .{ .name = "canister_inspect_message" });
}

pub fn globalTimer(func: anytype) void {
    @export(&func, .{ .name = "canister_global_timer" });
}

pub fn onLowWasmMemory(func: anytype) void {
    @export(&func, .{ .name = "canister_on_low_wasm_memory" });
}
