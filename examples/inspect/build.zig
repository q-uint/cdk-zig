const cdk = @import("cdk");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("cdk", .{});
    // Builds guestbook.wasm and guestbook_inspect.wasm.
    _ = cdk.addCanister(b, dep, "guestbook", .{ .inspect = true });
    _ = cdk.addTests(b, dep);
}
