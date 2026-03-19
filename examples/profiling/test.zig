const std = @import("std");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn readWasm(name: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, name, 10 * 1024 * 1024);
}

fn callUpdate(pocket: *pic.PocketIc, cid: []const u8, method: []const u8) !void {
    const result = try pocket.updateCall(cid, pic.principal.anonymous, method, "");
    switch (result) {
        .reply => |data| allocator.free(data),
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

fn deployAndTrace(pocket: *pic.PocketIc, wasm: []const u8) ![]const u8 {
    const cid = try pocket.createCanister();
    errdefer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);
    try callUpdate(pocket, cid, "__toggle_tracing");
    try callUpdate(pocket, cid, "compute");
    return cid;
}

test "profiling trace produces folded stacks" {
    const wasm = try readWasm("zig-out/bin/profiling.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try deployAndTrace(&pocket, wasm);
    defer allocator.free(cid);

    // Fetch instruction flamegraph.
    var trace = try pic.flamegraph.fetch(allocator, &pocket, cid, .instructions);
    defer trace.deinit();

    try std.testing.expect(trace.lines.items.len > 0);
    try std.testing.expect(trace.total_cost > 0);

    var found_compute = false;
    for (trace.lines.items) |line| {
        if (std.mem.indexOf(u8, line.stack, "compute") != null) {
            found_compute = true;
            break;
        }
    }
    try std.testing.expect(found_compute);

    try trace.writeFoldedStacks("profile.folded");
}

test "stable memory flamegraph tracks page growth" {
    const wasm = try readWasm("zig-out/bin/profiling.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try deployAndTrace(&pocket, wasm);
    defer allocator.free(cid);

    var trace = try pic.flamegraph.fetch(allocator, &pocket, cid, .stable_pages);
    defer trace.deinit();

    // The persist function grows stable memory, so we should see cost > 0.
    try std.testing.expect(trace.total_cost > 0);

    var found_persist = false;
    for (trace.lines.items) |line| {
        if (std.mem.indexOf(u8, line.stack, "persist") != null) {
            found_persist = true;
            break;
        }
    }
    try std.testing.expect(found_persist);

    try trace.writeFoldedStacks("stable.folded");
}

test "heap memory flamegraph" {
    const wasm = try readWasm("zig-out/bin/profiling.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try deployAndTrace(&pocket, wasm);
    defer allocator.free(cid);

    var trace = try pic.flamegraph.fetch(allocator, &pocket, cid, .heap_bytes);
    defer trace.deinit();

    try trace.writeFoldedStacks("heap.folded");
}

test "__get_cycles returns instruction count" {
    const wasm = try readWasm("zig-out/bin/profiling.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const result = try pocket.queryCall(cid, pic.principal.anonymous, "__get_cycles", "");
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqual(@as(usize, 8), data.len);
            const cycles = std.mem.readInt(i64, data[0..8], .little);
            try std.testing.expect(cycles > 0);
        },
        .reject => |msg| {
            defer allocator.free(msg);
            return error.Rejected;
        },
    }
}

test "tracing disabled by default produces empty trace" {
    const wasm = try readWasm("zig-out/bin/profiling.wasm");
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Call compute without enabling tracing.
    try callUpdate(&pocket, cid, "compute");

    // Trace should be empty.
    var trace = try pic.flamegraph.fetch(allocator, &pocket, cid, .instructions);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.lines.items.len);
    try std.testing.expectEqual(@as(i64, 0), trace.total_cost);
}
