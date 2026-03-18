const cdk = @import("cdk");

fn greet() callconv(.c) void {
    cdk.replyRaw("hello from callee");
}

comptime {
    cdk.query(greet, "greet");
}
