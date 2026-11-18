const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

// Mirrors probe.zig's `absent` by hand; probe.zig is wasm-only.
const absent_callee = "tz2ag-zx777-77776-aaabq-cai";

fn initPic() !pic.PocketIc {
    const bin = std.testing.environ.getPosix("POCKET_IC_BIN") orelse return error.SkipZigTest;
    return pic.PocketIc.init(std.testing.io, allocator, .{ .bin_path = bin });
}

fn readWasm(name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, name, allocator, .limited(10 * 1024 * 1024));
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

test "instance lifecycle" {
    var pocket = try initPic();
    pocket.deinit();
}

test "create canister" {
    var pocket = try initPic();
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    try std.testing.expect(cid.len > 0);
}

test "time control" {
    var pocket = try initPic();
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
    var pocket = try initPic();
    defer pocket.deinit();

    try pocket.tick();
}

test "callee greet" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const result = try pocket.queryCall(callee_id, cdk.principal.anonymous, "greet", "");
    try expectReply(result, "hello from callee");
}

test "caller greet" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, "", .install);

    const result = try pocket.queryCall(caller_id, cdk.principal.anonymous, "greet", "");
    try expectReply(result, "hello from caller");
}

test "caller calls callee" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, callee_id.slice(), .install);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    try expectReply(result, "hello from callee");
}

test "query non-existent method returns reject" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    try pocket.installCode(cid, callee_wasm, "", .install);

    const result = try pocket.queryCall(cid, cdk.principal.anonymous, "no_such_method", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expect(msg.len > 0);
}

test "update non-existent method returns reject" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    try pocket.installCode(cid, callee_wasm, "", .install);

    const result = try pocket.updateCall(cid, cdk.principal.anonymous, "no_such_method", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expect(msg.len > 0);
}

test "caller without callee principal rejects call_greet" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try pocket.createCanister();
    // Install caller without providing a callee principal.
    try pocket.installCode(caller_id, caller_wasm, "", .install);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expect(msg.len > 0);
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
    const result = try pocket.queryCall(caller_id, cdk.principal.anonymous, "outstanding_bytes", "");
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
    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_chained_trapping", "");
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

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_undecodable_handled", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expectEqual(pic.RejectCode.CanisterReject, rej.code);
    try std.testing.expectEqualStrings("hello from callee", msg);

    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "an undecodable reply traps without onUndecodable" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_undecodable_trapping", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expectEqual(pic.RejectCode.CanisterError, rej.code);
    try std.testing.expect(std.mem.indexOf(u8, msg, "could not decode the reply") != null);

    // The trap rolled the callback back, and cleanup released the slot.
    try std.testing.expectEqual(@as(u32, 1), try greetingsFreed(&pocket, caller_id));
}

test "a continuation can send the next call" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_chained", "");
    try expectReply(result, "hello from callee and goodbye from callee");
}

test "call reaches its named continuation" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    try expectReply(result, "hello from callee");
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
    const msg = rej.message;
    // Naming the callee proves the bytes reached the system; a length check
    // also passes on the probe's own rejects, including the never-left one.
    try std.testing.expect(std.mem.indexOf(u8, msg, absent_callee) != null);
}

test "caller calls non-existent canister" {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    // Point the caller at the management canister, which has no greet.
    const caller_id = try pocket.createCanister();
    try pocket.installCode(
        caller_id,
        caller_wasm,
        cdk.principal.management_canister.slice(),
        .install,
    );

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    const msg = rej.message;
    try std.testing.expect(msg.len > 0);
}
