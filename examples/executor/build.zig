const cdk = @import("cdk");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("cdk", .{});
    _ = cdk.addCanister(b, dep, "callee");
    _ = cdk.addCanister(b, dep, "caller");
    _ = cdk.addTests(b, dep);
}
