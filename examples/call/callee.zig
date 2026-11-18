const cdk = @import("cdk");

fn greet() []const u8 {
    return "hello from callee";
}

fn farewell() []const u8 {
    return "goodbye from callee";
}

comptime {
    cdk.query(greet, "greet");
    cdk.query(farewell, "farewell");
}
