const cdk = @import("cdk");

fn greet() void {
    cdk.replyRaw("hello from callee");
}

fn farewell() void {
    cdk.replyRaw("goodbye from callee");
}

comptime {
    cdk.query(greet, "greet");
    cdk.query(farewell, "farewell");
}
