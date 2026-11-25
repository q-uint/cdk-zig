const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

const Entry = struct { name: []const u8, message: []const u8 };

test "the inspect build serves each pub log as stored" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const cid = try pocket.deploy("zig-out/bin/guestbook_inspect.wasm", "");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const book = pocket.canister(cdk.CborCodec, cid);
    _ = try book.update(a, u64, "sign", Entry{ .name = "ada", .message = "hi" });
    _ = try book.update(a, u64, "sign", Entry{ .name = "bob", .message = "hello" });

    const raw = pocket.canister(cdk.RawCodec, cid);
    try std.testing.expectEqual(2, try raw.query(a, u64, "__stable_entries_len", {}));

    // Stored as CBOR, decoded here with the codec the guestbook stores with.
    const second = try raw.query(a, []const u8, "__stable_entries", @as(u64, 1));
    const entry = try cdk.CborCodec.decode(a, Entry, second);
    try std.testing.expectEqualStrings("bob", entry.name);
    try std.testing.expectEqualStrings("hello", entry.message);

    const time = try raw.query(a, []const u8, "__stable_times", @as(u64, 0));
    try std.testing.expectEqual(8, time.len);

    _ = try raw.expectReject(a, .query, "__stable_entries", @as(u64, 2));
}

test "only controllers may call the inspect endpoints" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const cid = try pocket.deploy("zig-out/bin/guestbook_inspect.wasm", "");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const stranger = pocket.canister(cdk.RawCodec, cid).as(cdk.principal.canisterId(42));
    const reject = try stranger.expectReject(arena.allocator(), .query, "__stable_entries_len", {});
    try std.testing.expect(std.mem.indexOf(u8, reject.message, "dev endpoints") != null);
}

test "the plain build exports no inspect endpoints" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const cid = try pocket.deploy("zig-out/bin/guestbook.wasm", "");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const raw = pocket.canister(cdk.RawCodec, cid);
    _ = try raw.expectReject(arena.allocator(), .query, "__stable_entries_len", {});
}

const BuildMetadata = struct {
    version: []const u8,
    profiling: bool,
    inspect: bool,
    dev_access: std.json.Value,
};

fn expectInspect(path: []const u8, inspect: bool) !void {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const cid = try pocket.deploy(path, "");

    const json = try pocket.metadata(cid, "cdk:build") orelse return error.MissingMetadata;
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(BuildMetadata, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(inspect, parsed.value.inspect);
}

test "cdk:build says which build inspects" {
    try expectInspect("zig-out/bin/guestbook.wasm", false);
    try expectInspect("zig-out/bin/guestbook_inspect.wasm", true);
}
