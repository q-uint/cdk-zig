const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;
const anonymous = cdk.principal.anonymous;

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

const Kind = enum { query, update };

// Sends `arg` as JSON, or nothing for a method without one, and returns the
// raw reply or the reject message, both owned by the caller.
fn send(pocket: *pic.PocketIc, cid: cdk.principal.Principal, kind: Kind, method: []const u8, arg: anytype) !pic.WasmResult {
    const bytes = if (@TypeOf(arg) == void) "" else try std.json.Stringify.valueAlloc(allocator, arg, .{});
    defer if (@TypeOf(arg) != void) allocator.free(bytes);
    return switch (kind) {
        .query => pocket.queryCall(cid, anonymous, method, bytes),
        .update => pocket.updateCall(cid, anonymous, method, bytes),
    };
}

fn call(comptime T: type, pocket: *pic.PocketIc, cid: cdk.principal.Principal, kind: Kind, method: []const u8, arg: anytype) !std.json.Parsed(T) {
    switch (try send(pocket, cid, kind, method, arg)) {
        .reply => |data| {
            defer allocator.free(data);
            return std.json.parseFromSlice(T, allocator, data, .{ .allocate = .alloc_always });
        },
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

fn put(pocket: *pic.PocketIc, cid: cdk.principal.Principal, entry: Entry) !u64 {
    const count = try call(u64, pocket, cid, .update, "put", entry);
    defer count.deinit();
    return count.value;
}

test "put, get and list speak JSON" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try install(&pocket);

    try std.testing.expectEqual(@as(u64, 1), try put(&pocket, cid, .{ .key = "color", .value = "blue" }));
    try std.testing.expectEqual(@as(u64, 2), try put(&pocket, cid, .{ .key = "shape", .value = "round" }));
    // Overwriting keeps the count.
    try std.testing.expectEqual(@as(u64, 2), try put(&pocket, cid, .{ .key = "color", .value = "green" }));

    const color = try call([]const u8, &pocket, cid, .query, "get", @as([]const u8, "color"));
    defer color.deinit();
    try std.testing.expectEqualStrings("green", color.value);

    const entries = try call([]const Entry, &pocket, cid, .query, "list", {});
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
    const cid = try install(&pocket);

    switch (try send(&pocket, cid, .query, "get", @as([]const u8, "size"))) {
        .reply => |data| {
            allocator.free(data);
            return error.ExpectedReject;
        },
        .reject => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings("NoSuchKey", msg);
        },
    }
}

test "count overrides the codec with Raw" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try install(&pocket);

    _ = try put(&pocket, cid, .{ .key = "color", .value = "blue" });
    switch (try send(&pocket, cid, .query, "count", {})) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, data[0..8], .little));
        },
        .reject => |msg| {
            defer allocator.free(msg);
            return error.Rejected;
        },
    }
}
