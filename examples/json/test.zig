const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");
const Json = @import("codec.zig");

const allocator = std.testing.allocator;

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

test "put, get and list speak JSON" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = pocket.canister(Json, try pocket.deploy("zig-out/bin/json.wasm", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(1, try store.update(a, u64, "put", Entry{ .key = "color", .value = "blue" }));
    try std.testing.expectEqual(2, try store.update(a, u64, "put", Entry{ .key = "shape", .value = "round" }));
    // Overwriting keeps the count.
    try std.testing.expectEqual(2, try store.update(a, u64, "put", Entry{ .key = "color", .value = "green" }));

    const color = try store.query(a, []const u8, "get", @as([]const u8, "color"));
    try std.testing.expectEqualStrings("green", color);

    const entries = try store.query(a, []const Entry, "list", {});
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("color", entries[0].key);
    try std.testing.expectEqualStrings("green", entries[0].value);
    try std.testing.expectEqualStrings("shape", entries[1].key);
    try std.testing.expectEqualStrings("round", entries[1].value);
}

test "a missing key rejects with the error's name" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = pocket.canister(Json, try pocket.deploy("zig-out/bin/json.wasm", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rej = try store.expectReject(arena.allocator(), .query, "get", @as([]const u8, "size"));
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.code);
    try std.testing.expectEqualStrings("NoSuchKey", rej.message);
}

test "a malformed argument rejects instead of trapping" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = pocket.canister(Json, try pocket.deploy("zig-out/bin/json.wasm", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Raw, to send bytes that are not JSON.
    const raw = store.with(cdk.RawCodec);
    const rej = try raw.expectReject(arena.allocator(), .update, "put", @as([]const u8, "{not json"));
    // A reject, not a trap.
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.code);
    try std.testing.expect(std.mem.startsWith(u8, rej.message, "cdk: could not decode the argument"));
}

test "count overrides the codec with Raw" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = pocket.canister(Json, try pocket.deploy("zig-out/bin/json.wasm", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try store.update(a, u64, "put", Entry{ .key = "color", .value = "blue" });
    try std.testing.expectEqual(1, try store.queryWith(a, cdk.RawCodec, u64, "count", {}));
}
