const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn deploy(pocket: *pic.PocketIc, path: []const u8) !pic.Canister(cdk.RawCodec) {
    return pocket.canister(cdk.RawCodec, try pocket.deploy(path, ""));
}

// The offset, then the payload.
fn writeArg(a: std.mem.Allocator, offset: u64, payload: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ &std.mem.toBytes(offset), payload });
}

// The offset, then the length.
fn readArg(offset: u64, len: u64) [16]u8 {
    return std.mem.toBytes(offset) ++ std.mem.toBytes(len);
}

test "stable_size starts at zero" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectEqual(0, try c.query(arena.allocator(), u64, "get_size", {}));
}

test "grow and size" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Grow by 3 pages, should return old size (0).
    try std.testing.expectEqual(0, try c.update(a, u64, "grow", @as(u64, 3)));
    try std.testing.expectEqual(3, try c.query(a, u64, "get_size", {}));
}

test "write and read round-trip" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try c.update(a, u64, "grow", @as(u64, 1));
    const payload = "hello stable";
    _ = try c.update(a, []const u8, "write", try writeArg(a, 100, payload));
    const read = try c.query(a, []const u8, "read", &readArg(100, payload.len));
    try std.testing.expectEqualStrings(payload, read);
}

test "write and read at page boundary" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try c.update(a, u64, "grow", @as(u64, 2));

    // Write across the page boundary (offset 65534, 4 bytes spans into page 2).
    const boundary_offset: u64 = 64 * 1024 - 2;
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    _ = try c.update(a, []const u8, "write", try writeArg(a, boundary_offset, &data));
    const read = try c.query(a, []const u8, "read", &readArg(boundary_offset, data.len));
    try std.testing.expectEqualSlices(u8, &data, read);
}

test "streaming writer and reader" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // stream_write splits the payload in half internally and writes both.
    const payload = "the quick brown fox jumps over the lazy dog";
    try std.testing.expectEqual(payload.len, try c.update(a, u64, "stream_write", payload));

    // stream_read from offset 0.
    const read = try c.query(a, []const u8, "stream_read", @as(u64, payload.len));
    try std.testing.expectEqualStrings(payload, read);
}

test "counter persists across upgrade" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (0..3) |_| _ = try c.update(a, []const u8, "increment", {});
    try std.testing.expectEqual(3, try c.query(a, u32, "get_counter", {}));

    // Upgrade (triggers pre_upgrade -> post_upgrade).
    try pocket.redeploy(c.id, "zig-out/bin/stable.wasm", .upgrade);

    // Counter should survive the upgrade.
    try std.testing.expectEqual(3, try c.query(a, u32, "get_counter", {}));
}

test "wasm64: write and read round-trip" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const c = try deploy(&pocket, "zig-out/bin/stable64.wasm");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try c.update(a, u64, "grow", @as(u64, 1));
    const payload = "hello wasm64";
    _ = try c.update(a, []const u8, "write", try writeArg(a, 100, payload));
    const read = try c.query(a, []const u8, "read", &readArg(100, payload.len));
    try std.testing.expectEqualStrings(payload, read);
}
