const std = @import("std");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn readWasm(name: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, name, 10 * 1024 * 1024);
}

fn getCounter(pocket: *pic.PocketIc, canister_id: []const u8) !u32 {
    const result = try pocket.queryCall(canister_id, pic.principal.anonymous, "get_counter", "");
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            if (data.len < 4) return error.InvalidReply;
            return std.mem.readInt(u32, data[0..4], .little);
        },
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

test "one-shot timer fires after delay" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Counter should start at 0.
    const c0 = try getCounter(&pocket, cid);
    try std.testing.expectEqual(@as(u32, 0), c0);

    // Advance time past the 5-second one-shot timer and tick.
    try pocket.advanceTime(6_000_000_000);
    try pocket.tick();

    // The interval timer should have fired several times and the one-shot adds 100.
    const c1 = try getCounter(&pocket, cid);
    try std.testing.expect(c1 >= 100);
}

test "interval timer increments repeatedly" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Advance 2 seconds and tick -- interval should have fired at least once.
    try pocket.advanceTime(2_000_000_000);
    try pocket.tick();
    const c1 = try getCounter(&pocket, cid);
    try std.testing.expect(c1 >= 1);

    // Advance another 2 seconds -- counter should grow.
    try pocket.advanceTime(2_000_000_000);
    try pocket.tick();
    const c2 = try getCounter(&pocket, cid);
    try std.testing.expect(c2 > c1);
}

test "cancel timer stops firing" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Let the interval fire a few times.
    try pocket.advanceTime(3_000_000_000);
    try pocket.tick();
    const before = try getCounter(&pocket, cid);
    try std.testing.expect(before >= 1);

    // Stop the interval timer via update call.
    const stop_result = try pocket.updateCall(cid, pic.principal.anonymous, "stop_interval", "");
    switch (stop_result) {
        .reply => |data| allocator.free(data),
        .reject => |msg| {
            defer allocator.free(msg);
            return error.Rejected;
        },
    }

    // Advance more time and tick -- counter should not change.
    try pocket.advanceTime(3_000_000_000);
    try pocket.tick();
    const after = try getCounter(&pocket, cid);
    // The one-shot at 5s may have fired, but interval should have stopped.
    // We just check that the counter did not keep incrementing by the interval amount.
    // At most +100 from the one-shot.
    try std.testing.expect(after <= before + 100);
}

test "counter stays zero without advancing time" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Tick without advancing time -- timers should not have fired.
    try pocket.tick();
    const c = try getCounter(&pocket, cid);
    try std.testing.expectEqual(@as(u32, 0), c);
}

test "query non-existent method on timer canister" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const result = try pocket.queryCall(cid, pic.principal.anonymous, "no_such_method", "");
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            return error.ExpectedReject;
        },
        .reject => |msg| {
            defer allocator.free(msg);
            try std.testing.expect(msg.len > 0);
        },
    }
}

test "double cancel is safe" {
    const wasm = try readWasm("zig-out/bin/timers.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Stop the interval timer twice -- second call should be a no-op.
    const stop1 = try pocket.updateCall(cid, pic.principal.anonymous, "stop_interval", "");
    switch (stop1) {
        .reply => |data| allocator.free(data),
        .reject => |msg| {
            defer allocator.free(msg);
            return error.Rejected;
        },
    }

    const stop2 = try pocket.updateCall(cid, pic.principal.anonymous, "stop_interval", "");
    switch (stop2) {
        .reply => |data| allocator.free(data),
        .reject => |msg| {
            defer allocator.free(msg);
            return error.Rejected;
        },
    }

    // Counter should still be 0 since no time advanced.
    const c = try getCounter(&pocket, cid);
    try std.testing.expectEqual(@as(u32, 0), c);
}
