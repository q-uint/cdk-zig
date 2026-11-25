const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn deploy(pocket: *pic.PocketIc) !pic.Canister(cdk.RawCodec) {
    return pocket.canister(cdk.RawCodec, try pocket.deploy("zig-out/bin/timers.wasm", ""));
}

test "one-shot timer fires after delay" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(0, try c.query(a, u32, "get_counter", {}));

    // Advance time past the 5-second one-shot timer and tick.
    try pocket.advanceTime(6_000_000_000);
    try pocket.tick();

    // The interval timer should have fired several times and the one-shot adds 100.
    try std.testing.expect(try c.query(a, u32, "get_counter", {}) >= 100);
}

test "interval timer increments repeatedly" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Advance 2 seconds and tick -- interval should have fired at least once.
    try pocket.advanceTime(2_000_000_000);
    try pocket.tick();
    const c1 = try c.query(a, u32, "get_counter", {});
    try std.testing.expect(c1 >= 1);

    // Advance another 2 seconds -- counter should grow.
    try pocket.advanceTime(2_000_000_000);
    try pocket.tick();
    try std.testing.expect(try c.query(a, u32, "get_counter", {}) > c1);
}

test "cancel timer stops firing" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Let the interval fire a few times.
    try pocket.advanceTime(3_000_000_000);
    try pocket.tick();
    const before = try c.query(a, u32, "get_counter", {});
    try std.testing.expect(before >= 1);

    _ = try c.update(a, []const u8, "stop_interval", {});

    // Advance more time and tick -- counter should not change.
    try pocket.advanceTime(3_000_000_000);
    try pocket.tick();
    // The one-shot at 5s may have fired, but interval should have stopped.
    // At most +100 from the one-shot.
    try std.testing.expect(try c.query(a, u32, "get_counter", {}) <= before + 100);
}

test "counter stays zero without advancing time" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Tick without advancing time -- timers should not have fired.
    try pocket.tick();
    try std.testing.expectEqual(0, try c.query(arena.allocator(), u32, "get_counter", {}));
}

test "query non-existent method on timer canister" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rej = try c.expectReject(arena.allocator(), .query, "no_such_method", {});
    try std.testing.expect(rej.message.len > 0);
}

test "double cancel is safe" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Stop the interval timer twice -- second call should be a no-op.
    _ = try c.update(a, []const u8, "stop_interval", {});
    _ = try c.update(a, []const u8, "stop_interval", {});

    // Counter should still be 0 since no time advanced.
    try std.testing.expectEqual(0, try c.query(a, u32, "get_counter", {}));
}
