const cdk = @import("cdk");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("cdk", .{});
    _ = cdk.addCanister(b, dep, "stable", .{});
    _ = cdk.addCanister(b, dep, "stable64", .{ .wasm64 = true, .root_source_file = "stable.zig" });
    _ = cdk.addTests(b, dep);
}
