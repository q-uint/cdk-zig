const cdk = @import("cdk");

fn greet() void {
    cdk.replyRaw("hello");
}

fn farewell() void {
    cdk.replyRaw("goodbye");
}

comptime {
    cdk.query(greet, "greet");
    cdk.query(farewell, "farewell");
}
