const std = @import("std");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn readWasm(name: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, name, 10 * 1024 * 1024);
}

fn expectReply(result: pic.WasmResult, expected: []const u8) !void {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(expected, data);
        },
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

fn expectReject(result: pic.WasmResult) ![]const u8 {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            return error.ExpectedReject;
        },
        .reject => |msg| {
            return msg;
        },
    }
}

test "chained call via executor" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    defer allocator.free(callee_id);
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const callee_text = pic.principal.encode(callee_id);
    const caller_id = try pocket.createCanister();
    defer allocator.free(caller_id);
    try pocket.installCode(caller_id, caller_wasm, callee_text, .install);

    const result = try pocket.updateCall(caller_id, pic.principal.anonymous, "chained_call", "");
    try expectReply(result, "hello and goodbye");
}

test "chained call without callee principal traps" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const caller_id = try pocket.createCanister();
    defer allocator.free(caller_id);
    // Install without callee principal.
    try pocket.installCode(caller_id, caller_wasm, "", .install);

    const result = try pocket.updateCall(caller_id, pic.principal.anonymous, "chained_call", "");
    const msg = try expectReject(result);
    defer allocator.free(msg);
    try std.testing.expect(msg.len > 0);
}

test "chained call to non-existent canister rejects" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const caller_id = try pocket.createCanister();
    defer allocator.free(caller_id);
    // Point to the management canister which won't have greet/farewell.
    try pocket.installCode(caller_id, caller_wasm, "aaaaa-aa", .install);

    const result = try pocket.updateCall(caller_id, pic.principal.anonymous, "chained_call", "");
    const msg = try expectReject(result);
    defer allocator.free(msg);
    try std.testing.expect(msg.len > 0);
}
