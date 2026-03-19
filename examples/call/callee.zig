const cdk = @import("cdk");

fn greet() void {
    cdk.replyRaw("hello from callee");
}

comptime {
    cdk.query(greet, "greet");
}
