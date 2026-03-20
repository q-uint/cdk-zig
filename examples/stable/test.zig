const std = @import("std");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn readWasm() ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, "zig-out/bin/stable.wasm", 10 * 1024 * 1024);
}

fn readWasm64() ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, "zig-out/bin/stable64.wasm", 10 * 1024 * 1024);
}

fn expectReply(
    pocket: *pic.PocketIc,
    cid: []const u8,
    method: []const u8,
    arg: []const u8,
    comptime call_type: enum { query, update },
) ![]const u8 {
    const result = switch (call_type) {
        .query => try pocket.queryCall(cid, pic.principal.anonymous, method, arg),
        .update => try pocket.updateCall(cid, pic.principal.anonymous, method, arg),
    };
    switch (result) {
        .reply => |data| return data,
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

test "stable_size starts at zero" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const data = try expectReply(&pocket, cid, "get_size", "", .query);
    defer allocator.free(data);

    const pages = std.mem.readInt(u64, data[0..8], .little);
    try std.testing.expectEqual(@as(u64, 0), pages);
}

test "grow and size" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Grow by 3 pages, should return old size (0).
    const grow_reply = try expectReply(&pocket, cid, "grow", &std.mem.toBytes(@as(u64, 3)), .update);
    defer allocator.free(grow_reply);
    const old_size = std.mem.readInt(u64, grow_reply[0..8], .little);
    try std.testing.expectEqual(@as(u64, 0), old_size);

    // Size should now be 3.
    const size_reply = try expectReply(&pocket, cid, "get_size", "", .query);
    defer allocator.free(size_reply);
    const pages = std.mem.readInt(u64, size_reply[0..8], .little);
    try std.testing.expectEqual(@as(u64, 3), pages);
}

test "write and read round-trip" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Grow 1 page.
    const grow_reply = try expectReply(&pocket, cid, "grow", &std.mem.toBytes(@as(u64, 1)), .update);
    allocator.free(grow_reply);

    // Write "hello stable" at offset 100.
    const payload = "hello stable";
    var write_arg: [8 + payload.len]u8 = undefined;
    @memcpy(write_arg[0..8], &std.mem.toBytes(@as(u64, 100)));
    @memcpy(write_arg[8..], payload);
    const write_reply = try expectReply(&pocket, cid, "write", &write_arg, .update);
    allocator.free(write_reply);

    // Read back 12 bytes from offset 100.
    var read_arg: [16]u8 = undefined;
    @memcpy(read_arg[0..8], &std.mem.toBytes(@as(u64, 100)));
    @memcpy(read_arg[8..16], &std.mem.toBytes(@as(u64, payload.len)));
    const read_reply = try expectReply(&pocket, cid, "read", &read_arg, .query);
    defer allocator.free(read_reply);

    try std.testing.expectEqualStrings(payload, read_reply);
}

test "write and read at page boundary" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Grow 2 pages (128 KiB).
    const grow_reply = try expectReply(&pocket, cid, "grow", &std.mem.toBytes(@as(u64, 2)), .update);
    allocator.free(grow_reply);

    // Write across the page boundary (offset 65534, 4 bytes spans into page 2).
    const boundary_offset: u64 = 64 * 1024 - 2;
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var write_arg: [8 + data.len]u8 = undefined;
    @memcpy(write_arg[0..8], &std.mem.toBytes(boundary_offset));
    @memcpy(write_arg[8..], &data);
    const write_reply = try expectReply(&pocket, cid, "write", &write_arg, .update);
    allocator.free(write_reply);

    // Read it back.
    var read_arg: [16]u8 = undefined;
    @memcpy(read_arg[0..8], &std.mem.toBytes(boundary_offset));
    @memcpy(read_arg[8..16], &std.mem.toBytes(@as(u64, data.len)));
    const read_reply = try expectReply(&pocket, cid, "read", &read_arg, .query);
    defer allocator.free(read_reply);

    try std.testing.expectEqualSlices(u8, &data, read_reply);
}

test "streaming writer and reader" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // stream_write splits the payload in half internally and writes both.
    const payload = "the quick brown fox jumps over the lazy dog";
    const sw_reply = try expectReply(&pocket, cid, "stream_write", payload, .update);
    defer allocator.free(sw_reply);
    const written = std.mem.readInt(u64, sw_reply[0..8], .little);
    try std.testing.expectEqual(@as(u64, payload.len), written);

    // stream_read from offset 0.
    const sr_reply = try expectReply(
        &pocket,
        cid,
        "stream_read",
        &std.mem.toBytes(@as(u64, payload.len)),
        .query,
    );
    defer allocator.free(sr_reply);
    try std.testing.expectEqualStrings(payload, sr_reply);
}

test "counter persists across upgrade" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Increment counter 3 times.
    for (0..3) |_| {
        const reply = try expectReply(&pocket, cid, "increment", "", .update);
        allocator.free(reply);
    }

    // Verify counter is 3.
    const before = try expectReply(&pocket, cid, "get_counter", "", .query);
    defer allocator.free(before);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, before[0..4], .little));

    // Upgrade (triggers pre_upgrade -> post_upgrade).
    try pocket.installCode(cid, wasm, "", .upgrade);

    // Counter should survive the upgrade.
    const after = try expectReply(&pocket, cid, "get_counter", "", .query);
    defer allocator.free(after);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, after[0..4], .little));
}

test "wasm64: write and read round-trip" {
    const wasm = try readWasm64();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Grow 1 page.
    const grow_reply = try expectReply(&pocket, cid, "grow", &std.mem.toBytes(@as(u64, 1)), .update);
    allocator.free(grow_reply);

    // Write "hello wasm64" at offset 100.
    const payload = "hello wasm64";
    var write_arg: [8 + payload.len]u8 = undefined;
    @memcpy(write_arg[0..8], &std.mem.toBytes(@as(u64, 100)));
    @memcpy(write_arg[8..], payload);
    const write_reply = try expectReply(&pocket, cid, "write", &write_arg, .update);
    allocator.free(write_reply);

    // Read back from offset 100.
    var read_arg: [16]u8 = undefined;
    @memcpy(read_arg[0..8], &std.mem.toBytes(@as(u64, 100)));
    @memcpy(read_arg[8..16], &std.mem.toBytes(@as(u64, payload.len)));
    const read_reply = try expectReply(&pocket, cid, "read", &read_arg, .query);
    defer allocator.free(read_reply);

    try std.testing.expectEqualStrings(payload, read_reply);
}
