const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

const Entry = struct { name: []const u8, message: []const u8 };

fn initPic() !pic.PocketIc {
    const bin = std.testing.environ.getPosix("POCKET_IC_BIN") orelse return error.SkipZigTest;
    return pic.PocketIc.init(std.testing.io, allocator, .{ .bin_path = bin });
}

fn deploy(pocket: *pic.PocketIc, path: []const u8) !cdk.principal.Principal {
    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(10 * 1024 * 1024),
    );
    defer allocator.free(wasm);
    const cid = try pocket.createCanister();
    try pocket.installCode(cid, wasm, "", .install);
    return cid;
}

test "the inspect build serves each pub log as stored" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, "zig-out/bin/guestbook_inspect.wasm");

    const book = pocket.canister(cdk.CborCodec, cid);
    (try book.update(u64, "sign", Entry{ .name = "ada", .message = "hi" })).deinit();
    (try book.update(u64, "sign", Entry{ .name = "bob", .message = "hello" })).deinit();

    const raw = pocket.canister(cdk.RawCodec, cid);
    const len = try raw.query(u64, "__stable_entries_len", {});
    defer len.deinit();
    try std.testing.expectEqual(2, len.value);

    // Stored as CBOR, decoded here with the codec the guestbook stores with.
    const second = try raw.query([]const u8, "__stable_entries", @as(u64, 1));
    defer second.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = try cdk.CborCodec.decode(arena.allocator(), Entry, second.value);
    try std.testing.expectEqualStrings("bob", entry.name);
    try std.testing.expectEqualStrings("hello", entry.message);

    const time = try raw.query([]const u8, "__stable_times", @as(u64, 0));
    defer time.deinit();
    try std.testing.expectEqual(8, time.value.len);

    const past = try raw.expectReject(.query, "__stable_entries", @as(u64, 2));
    defer past.deinit();
}

test "only controllers may call the inspect endpoints" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, "zig-out/bin/guestbook_inspect.wasm");

    const stranger = pocket.canister(cdk.RawCodec, cid).as(cdk.principal.canisterId(42));
    const reject = try stranger.expectReject(.query, "__stable_entries_len", {});
    defer reject.deinit();
    try std.testing.expect(std.mem.indexOf(u8, reject.value.message, "dev endpoints") != null);
}

test "the plain build exports no inspect endpoints" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, "zig-out/bin/guestbook.wasm");

    const raw = pocket.canister(cdk.RawCodec, cid);
    const reject = try raw.expectReject(.query, "__stable_entries_len", {});
    defer reject.deinit();
}

const BuildMetadata = struct {
    version: []const u8,
    profiling: bool,
    inspect: bool,
    dev_access: std.json.Value,
};

fn expectInspect(path: []const u8, inspect: bool) !void {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, path);

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
