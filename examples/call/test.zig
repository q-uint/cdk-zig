const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn installCaller(pocket: *pic.PocketIc, callee: []const u8) !pic.Canister(cdk.RawCodec) {
    return pocket.canister(cdk.RawCodec, try pocket.deploy("zig-out/bin/caller.wasm", callee));
}

fn installPair(pocket: *pic.PocketIc) !pic.Canister(cdk.RawCodec) {
    const callee_id = try pocket.deploy("zig-out/bin/callee.wasm", "");
    return installCaller(pocket, callee_id.slice());
}

test "callee greet" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const callee = pocket.canister(cdk.RawCodec, try pocket.deploy("zig-out/bin/callee.wasm", ""));
    const greeting = try callee.query(arena.allocator(), []const u8, "greet", {});
    try std.testing.expectEqualStrings("hello from callee", greeting);
}

test "caller greet" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const caller = try installCaller(&pocket, "");
    const greeting = try caller.query(arena.allocator(), []const u8, "greet", {});
    try std.testing.expectEqualStrings("hello from caller", greeting);
}

test "caller calls callee" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const caller = try installPair(&pocket);
    const greeting = try caller.update(arena.allocator(), []const u8, "call_greet", {});
    try std.testing.expectEqualStrings("hello from callee", greeting);
}

test "a continuation can send the next call" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const caller = try installPair(&pocket);
    const greeting = try caller.update(arena.allocator(), []const u8, "call_chained", {});
    try std.testing.expectEqualStrings("hello from callee and goodbye from callee", greeting);
}

test "caller without callee principal rejects call_greet" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const caller = try installCaller(&pocket, "");
    const rej = try caller.expectReject(arena.allocator(), .update, "call_greet", {});
    try std.testing.expect(rej.message.len > 0);
}

test "caller calls non-existent canister" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Point the caller at the management canister, which has no greet.
    const caller = try installCaller(&pocket, cdk.principal.management_canister.slice());
    const rej = try caller.expectReject(arena.allocator(), .update, "call_greet", {});
    try std.testing.expect(rej.message.len > 0);
}
