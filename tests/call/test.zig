const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

const chained = "hello from callee and goodbye from callee";

fn installPair(pocket: *pic.PocketIc) !pic.Canister(cdk.RawCodec) {
    const callee_id = try pocket.deploy("zig-out/bin/callee.wasm", "");
    const caller_id = try pocket.deploy("zig-out/bin/caller.wasm", callee_id.slice());
    return pocket.canister(cdk.RawCodec, caller_id);
}

test "query non-existent method returns reject" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rej = try caller.expectReject(arena.allocator(), .query, "no_such_method", {});
    try std.testing.expect(rej.message.len > 0);
}

test "update non-existent method returns reject" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rej = try caller.expectReject(arena.allocator(), .update, "no_such_method", {});
    try std.testing.expect(rej.message.len > 0);
}

test "a completed chained call leaves nothing allocated" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try caller.query(a, u64, "outstanding_bytes", {});
    try std.testing.expectEqualStrings(chained, try caller.update(a, []const u8, "call_chained", {}));
    try std.testing.expectEqual(before, try caller.query(a, u64, "outstanding_bytes", {}));
}

test "pending state is released when the call rejects" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(0, try caller.query(a, u32, "greetings_freed", {}));
    _ = try caller.expectReject(a, .update, "call_chained_rejecting", {});
    try std.testing.expectEqual(1, try caller.query(a, u32, "greetings_freed", {}));
}

test "pending state is released when the continuation traps" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try caller.expectReject(a, .update, "call_chained_trapping", {});
    try std.testing.expectEqual(1, try caller.query(a, u32, "greetings_freed", {}));
}

test "chained calls in flight at once each keep their pending state" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try caller.query(a, u64, "outstanding_bytes", {});

    // Both are submitted before either runs, so their messages interleave
    // and both greetings sit in pending slots at the same time.
    const first = try caller.submitUpdate("call_chained", {});
    const second = try caller.submitUpdate("call_chained", {});
    try std.testing.expectEqualStrings(chained, try caller.awaitUpdate(a, []const u8, second));
    try std.testing.expectEqualStrings(chained, try caller.awaitUpdate(a, []const u8, first));

    try std.testing.expectEqual(before, try caller.query(a, u64, "outstanding_bytes", {}));
}

test "a trapping continuation leaves its message in the canister log" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rej = try caller.expectReject(a, .update, "call_chained_trapping", {});
    try std.testing.expectEqual(pic.RejectCode.CanisterError, rej.code);

    for (try pocket.canisterLogs(a, caller.id, .{})) |record| {
        if (std.mem.indexOf(u8, record.content, "trapping on purpose") != null) break;
    } else return error.TrapNotLogged;
}

test "an undecodable reply reaches onUndecodable with its bytes" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rej = try caller.expectReject(a, .update, "call_undecodable_handled", {});
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.code);
    try std.testing.expectEqualStrings("hello from callee", rej.message);

    try std.testing.expectEqual(1, try caller.query(a, u32, "greetings_freed", {}));
}

test "an undecodable reply traps without onUndecodable" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rej = try caller.expectReject(a, .update, "call_undecodable_trapping", {});
    try std.testing.expectEqual(pic.RejectCode.CanisterError, rej.code);
    try std.testing.expect(std.mem.indexOf(u8, rej.message, "could not decode the reply") != null);

    // The trap rolled the callback back, and cleanup released the slot.
    try std.testing.expectEqual(1, try caller.query(a, u32, "greetings_freed", {}));
}

test "a comptime-known callee reaches the right canister" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const caller = try installPair(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rej = try caller.expectReject(arena.allocator(), .update, "call_comptime_callee", {});
    // Naming the callee proves the bytes reached the system; a length check
    // also passes on the caller's own rejects, including the never-left one.
    var buf: [cdk.principal.Principal.max_text_len]u8 = undefined;
    const absent = cdk.principal.toText(&buf, cdk.principal.canisterId(std.math.maxInt(u64)));
    try std.testing.expect(std.mem.indexOf(u8, rej.message, absent) != null);
}
