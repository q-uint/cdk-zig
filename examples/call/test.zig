const std = @import("std");
const pic = @import("pocket-ic");

const allocator = std.heap.page_allocator;

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

test "instance lifecycle" {
    var pocket = try pic.PocketIc.init(allocator, .{});
    pocket.deinit();
}

test "create canister" {
    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    try std.testing.expect(cid.len > 0);
}

test "time control" {
    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const t1 = try pocket.getTime();
    try std.testing.expect(t1 > 0);

    const target: u64 = 1_000_000_000_000_000_000; // 1e18 ns
    try pocket.setTime(target);
    const t2 = try pocket.getTime();
    try std.testing.expect(t2 >= target);

    const advance_ns: u64 = 5_000_000_000; // 5 seconds
    try pocket.advanceTime(advance_ns);
    const t3 = try pocket.getTime();
    try std.testing.expect(t3 >= t2 + advance_ns);
}

test "tick" {
    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    try pocket.tick();
}

test "callee greet" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const result = try pocket.queryCall(callee_id, pic.principal.anonymous, "greet", "");
    try expectReply(result, "hello from callee");
}

test "caller greet" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, "", .install);

    const result = try pocket.queryCall(caller_id, pic.principal.anonymous, "greet", "");
    try expectReply(result, "hello from caller");
}

test "caller calls callee" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const callee_text = pic.principal.encode(callee_id);
    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, callee_text, .install);

    const result = try pocket.updateCall(caller_id, pic.principal.anonymous, "call_greet", "");
    try expectReply(result, "hello from callee");
}
