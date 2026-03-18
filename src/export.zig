pub fn init(func: anytype) void {
    @export(&func, .{ .name = "canister_init" });
}

pub fn query(func: anytype, name: []const u8) void {
    @export(&func, .{ .name = "canister_query " ++ name });
}

pub fn update(func: anytype, name: []const u8) void {
    @export(&func, .{ .name = "canister_update " ++ name });
}
