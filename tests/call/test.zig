const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn initPic() !pic.PocketIc {
    const bin = std.testing.environ.getPosix("POCKET_IC_BIN") orelse return error.SkipZigTest;
    return pic.PocketIc.init(std.testing.io, allocator, .{ .bin_path = bin });
}

fn readWasm(name: []const u8) ![]const u8 {
    const limit: std.Io.Limit = .limited(10 * 1024 * 1024);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, name, allocator, limit);
}

fn expectReply(result: pic.WasmResult, expected: []const u8) !void {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(expected, data);
        },
        .reject => |rej| {
            defer rej.deinit(allocator);
            std.debug.print("rejected: {s}\n", .{rej.message});
            return error.Rejected;
        },
    }
}

fn expectReject(result: pic.WasmResult) !pic.Reject {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            return error.ExpectedReject;
        },
        .reject => |rej| return rej,
    }
}

fn installPair(pocket: *pic.PocketIc) !cdk.principal.Principal {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, callee_id.slice(), .install);
    return caller_id;
}

fn greetingsFreed(pocket: *pic.PocketIc, caller_id: cdk.principal.Principal) !u32 {
    const result = try pocket.queryCall(caller_id, cdk.principal.anonymous, "greetings_freed", "");
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqual(@as(usize, 4), data.len);
            return std.mem.readInt(u32, data[0..4], .little);
        },
        .reject => |rej| {
            defer rej.deinit(allocator);
            return error.Rejected;
        },
    }
}

fn outstandingBytes(pocket: *pic.PocketIc, caller_id: cdk.principal.Principal) !u64 {
    const result = try pocket.queryCall(
        caller_id,
        cdk.principal.anonymous,
        "outstanding_bytes",
        "",
    );
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqual(@as(usize, 8), data.len);
            return std.mem.readInt(u64, data[0..8], .little);
        },
        .reject => |rej| {
            defer rej.deinit(allocator);
            return error.Rejected;
        },
    }
}

test "query non-existent method returns reject" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.queryCall(caller_id, cdk.principal.anonymous, "no_such_method", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expect(rej.message.len > 0);
}

test "update non-existent method returns reject" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "no_such_method", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expect(rej.message.len > 0);
}

test "a completed chained call leaves nothing allocated" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const before = try outstandingBytes(&pocket, caller_id);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_chained", "");
    try expectReply(result, "hello from callee and goodbye from callee");

    try std.testing.expectEqual(before, try outstandingBytes(&pocket, caller_id));
}

test "pending state is released when the call rejects" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    try std.testing.expectEqual(@as(u32, 0), try greetingsFreed(&pocket, caller_id));

    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_chained_rejecting",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "pending state is released when the continuation traps" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_chained_trapping",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "chained calls in flight at once each keep their pending state" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);
    const before = try outstandingBytes(&pocket, caller_id);

    // Both are submitted before either runs, so their messages interleave
    // and both greetings sit in pending slots at the same time.
    const first = try pocket.submitUpdate(caller_id, cdk.principal.anonymous, "call_chained", "");
    const second = try pocket.submitUpdate(caller_id, cdk.principal.anonymous, "call_chained", "");
    try expectReply(try pocket.awaitUpdate(second), "hello from callee and goodbye from callee");
    try expectReply(try pocket.awaitUpdate(first), "hello from callee and goodbye from callee");

    try std.testing.expectEqual(before, try outstandingBytes(&pocket, caller_id));
}

test "a trapping continuation leaves its message in the canister log" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);
    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_chained_trapping",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expectEqual(pic.RejectCode.CanisterError, rej.code);

    const logs = try pocket.canisterLogs(caller_id, .{});
    defer logs.deinit();
    for (logs.value) |record| {
        if (std.mem.indexOf(u8, record.content, "trapping on purpose") != null) break;
    } else return error.TrapNotLogged;
}

test "an undecodable reply reaches onUndecodable with its bytes" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_undecodable_handled",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.code);
    try std.testing.expectEqualStrings("hello from callee", rej.message);

    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "an undecodable reply traps without onUndecodable" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_undecodable_trapping",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expectEqual(pic.RejectCode.CanisterError, rej.code);
    try std.testing.expect(std.mem.indexOf(u8, rej.message, "could not decode the reply") != null);

    // The trap rolled the callback back, and cleanup released the slot.
    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "a comptime-known callee reaches the right canister" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(
        caller_id,
        cdk.principal.anonymous,
        "call_comptime_callee",
        "",
    );
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    // Naming the callee proves the bytes reached the system; a length check
    // also passes on the caller's own rejects, including the never-left one.
    var buf: [cdk.principal.Principal.max_text_len]u8 = undefined;
    const absent = cdk.principal.toText(&buf, cdk.principal.canisterId(std.math.maxInt(u64)));
    try std.testing.expect(std.mem.indexOf(u8, rej.message, absent) != null);
}
