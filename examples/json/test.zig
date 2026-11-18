const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");
const Json = @import("codec.zig");

const allocator = std.testing.allocator;

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

fn initPic() !pic.PocketIc {
    const bin = std.testing.environ.getPosix("POCKET_IC_BIN") orelse return error.SkipZigTest;
    return pic.PocketIc.init(std.testing.io, allocator, .{ .bin_path = bin });
}

fn install(pocket: *pic.PocketIc) !cdk.principal.Principal {
    const wasm = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "zig-out/bin/json.wasm", allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(wasm);
    const cid = try pocket.createCanister();
    try pocket.installCode(cid, wasm, "", .install);
    return cid;
}

fn put(store: pic.Canister(Json), entry: Entry) !u64 {
    const count = try store.update(u64, "put", entry);
    defer count.deinit();
    return count.value;
}

test "put, get and list speak JSON" {
    var pocket = try initPic();
    defer pocket.deinit();
    const store = pocket.canister(Json, try install(&pocket));

    try std.testing.expectEqual(@as(u64, 1), try put(store, .{ .key = "color", .value = "blue" }));
    try std.testing.expectEqual(@as(u64, 2), try put(store, .{ .key = "shape", .value = "round" }));
    // Overwriting keeps the count.
    try std.testing.expectEqual(@as(u64, 2), try put(store, .{ .key = "color", .value = "green" }));

    const color = try store.query([]const u8, "get", @as([]const u8, "color"));
    defer color.deinit();
    try std.testing.expectEqualStrings("green", color.value);

    const entries = try store.query([]const Entry, "list", {});
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 2), entries.value.len);
    try std.testing.expectEqualStrings("color", entries.value[0].key);
    try std.testing.expectEqualStrings("green", entries.value[0].value);
    try std.testing.expectEqualStrings("shape", entries.value[1].key);
    try std.testing.expectEqualStrings("round", entries.value[1].value);
}

test "a missing key rejects with the error's name" {
    var pocket = try initPic();
    defer pocket.deinit();
    const store = pocket.canister(Json, try install(&pocket));

    const rej = try store.expectReject(.query, "get", @as([]const u8, "size"));
    defer rej.deinit();
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.value.code);
    try std.testing.expectEqualStrings("NoSuchKey", rej.value.message);
}

test "a malformed argument rejects instead of trapping" {
    var pocket = try initPic();
    defer pocket.deinit();
    const store = pocket.canister(Json, try install(&pocket));

    // Raw, to send bytes that are not JSON.
    const rej = try store.with(cdk.RawCodec).expectReject(.update, "put", @as([]const u8, "{not json"));
    defer rej.deinit();
    // A reject, not a trap.
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.value.code);
    try std.testing.expect(std.mem.startsWith(u8, rej.value.message, "cdk: could not decode the argument"));
}

test "count overrides the codec with Raw" {
    var pocket = try initPic();
    defer pocket.deinit();
    const store = pocket.canister(Json, try install(&pocket));

    _ = try put(store, .{ .key = "color", .value = "blue" });

    const count = try store.queryWith(cdk.RawCodec, u64, "count", {});
    defer count.deinit();
    try std.testing.expectEqual(@as(u64, 1), count.value);
}
