const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");
const candid = @import("cdk").candid;

const allocator = std.testing.allocator;

const Greeting = struct {
    greeting: []const u8,
};

test "callee greet" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const callee_id = try pocket.deploy("zig-out/bin/callee.wasm", "");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const callee = pocket.canister(cdk.CandidCodec, callee_id);
    const g = try callee.query(arena.allocator(), Greeting, "greet", @as([]const u8, "world"));
    try std.testing.expectEqualStrings("hello, world!", g.greeting);
}

test "caller calls callee" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const callee_id = try pocket.deploy("zig-out/bin/callee.wasm", "");
    const caller_id = try pocket.deploy("zig-out/bin/caller.wasm", try candid.encode(a, .{callee_id}));

    const caller = pocket.canister(cdk.CandidCodec, caller_id);
    const g = try caller.update(a, Greeting, "call_greet", {});
    try std.testing.expectEqualStrings("hello, world!", g.greeting);
}
