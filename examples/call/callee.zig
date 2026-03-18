const cdk = @import("cdk");

fn greet() callconv(.c) void {
    cdk.reply_raw("hello from callee");
}

comptime {
    cdk.query(greet, "greet");
}
