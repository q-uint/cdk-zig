const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

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

fn deployProfiling(pocket: *pic.PocketIc) !cdk.principal.Principal {
    return deploy(pocket, "zig-out/bin/compute_profiling.wasm");
}

fn raw(pocket: *pic.PocketIc, cid: cdk.principal.Principal) pic.Canister(cdk.RawCodec) {
    return pocket.canister(cdk.RawCodec, cid);
}

// One profiled call of `compute`.
fn profileCompute(pocket: *pic.PocketIc, metric: pic.flamegraph.Metric) !pic.flamegraph.Trace {
    const cid = try deployProfiling(pocket);
    return pocket.profiler(cid).profile(allocator, "compute", {}, metric);
}

fn hasFrame(trace: *const pic.flamegraph.Trace, name: []const u8) bool {
    for (trace.lines.items) |line| {
        if (std.mem.indexOf(u8, line.stack, name) != null) return true;
    }
    return false;
}

test "profiling trace produces folded stacks" {
    var pocket = try initPic();
    defer pocket.deinit();

    var trace = try profileCompute(&pocket, .instructions);
    defer trace.deinit();

    try std.testing.expect(trace.lines.items.len > 0);
    try std.testing.expect(trace.total_cost > 0);
    try std.testing.expect(hasFrame(&trace, "compute"));
    try std.testing.expectEqual(@as(usize, 0), trace.unbalanced);

    try trace.writeFoldedStacks(std.testing.io, "profile.folded");
}

test "inclusive and exclusive costs" {
    var pocket = try initPic();
    defer pocket.deinit();

    var trace = try profileCompute(&pocket, .instructions);
    defer trace.deinit();

    // process calls validate, transform and persist, so its inclusive cost
    // covers theirs and its exclusive cost does not.
    const process = trace.inclusive("process");
    const callees = trace.inclusive("validate") +
        trace.inclusive("transform") +
        trace.inclusive("persist");
    try std.testing.expect(callees > 0);
    try std.testing.expectEqual(process, trace.exclusive("process") + callees);

    // The entry point's frame covers the whole call.
    try std.testing.expectEqual(trace.total_cost, trace.inclusive("compute"));
    try std.testing.expectEqual(@as(i64, 0), trace.inclusive("no_such_frame"));
}

test "stable memory flamegraph tracks page growth" {
    var pocket = try initPic();
    defer pocket.deinit();

    var trace = try profileCompute(&pocket, .stable_pages);
    defer trace.deinit();

    // persist grows stable memory by three pages.
    try std.testing.expectEqual(@as(i64, 3), trace.inclusive("persist"));
    try std.testing.expect(hasFrame(&trace, "persist"));

    try trace.writeFoldedStacks(std.testing.io, "stable.folded");
}

test "heap memory flamegraph" {
    var pocket = try initPic();
    defer pocket.deinit();

    var trace = try profileCompute(&pocket, .heap_bytes);
    defer trace.deinit();

    try std.testing.expect(trace.inclusive("commit") >= 256 * @sizeOf(u32));

    try trace.writeFoldedStacks(std.testing.io, "heap.folded");
}

test "a query is profiled through its update twin" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const profiler = pocket.profiler(cid);
    var trace = try profiler.profileQuery(allocator, "get_counter", {}, .instructions);
    defer trace.deinit();

    try std.testing.expect(trace.inclusive("get_counter") > 0);
    try std.testing.expect(trace.inclusive("read_counter") > 0);
    try std.testing.expect(hasFrame(&trace, "get_counter;read_counter"));
}

test "a section closes on an early error return" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const profiler = pocket.profiler(cid);
    try profiler.start(.{});
    const reject = try raw(&pocket, cid).expectReject(.update, "check", @as(u8, 1));
    defer reject.deinit();

    var trace = try profiler.trace(allocator, .instructions);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.unbalanced);
    try std.testing.expect(hasFrame(&trace, "check;verify"));
}

test "last_call_only keeps one call" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const profiler = pocket.profiler(cid);
    const canister = raw(&pocket, cid);

    try profiler.start(.{});
    (try canister.update([]const u8, "compute", {})).deinit();
    (try canister.update([]const u8, "compute", {})).deinit();
    var both = try profiler.trace(allocator, .instructions);
    defer both.deinit();

    try profiler.start(.{ .last_call_only = true });
    (try canister.update([]const u8, "compute", {})).deinit();
    (try canister.update([]const u8, "compute", {})).deinit();
    var last = try profiler.trace(allocator, .instructions);
    defer last.deinit();

    try std.testing.expectEqual(@as(usize, 2), countLines(&both, "compute;parse_input"));
    try std.testing.expectEqual(@as(usize, 1), countLines(&last, "compute;parse_input"));
}

fn countLines(trace: *const pic.flamegraph.Trace, stack: []const u8) usize {
    var count: usize = 0;
    for (trace.lines.items) |line| {
        if (std.mem.eql(u8, line.stack, stack)) count += 1;
    }
    return count;
}

test "stop leaves later calls out of the trace" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const profiler = pocket.profiler(cid);
    try profiler.start(.{});
    try profiler.stop();
    (try raw(&pocket, cid).update([]const u8, "compute", {})).deinit();

    var trace = try profiler.trace(allocator, .instructions);
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 0), trace.lines.items.len);
}

test "__set_profiling rejects a malformed argument" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const reject = try raw(&pocket, cid).expectReject(.update, "__set_profiling", "\x02\x00");
    defer reject.deinit();
}

test "__get_instructions returns the instruction counter" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const count = try raw(&pocket, cid).query(i64, "__get_instructions", {});
    defer count.deinit();
    try std.testing.expect(count.value > 0);
}

test "tracing disabled by default produces empty trace" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    (try raw(&pocket, cid).update([]const u8, "compute", {})).deinit();

    var trace = try pocket.profiler(cid).trace(allocator, .instructions);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.lines.items.len);
    try std.testing.expectEqual(@as(i64, 0), trace.total_cost);
}

const BuildMetadata = struct {
    version: []const u8,
    profiling: bool,
    inspect: bool,
    dev_access: std.json.Value,
};

fn expectBuildMetadata(path: []const u8, profiling: bool) !void {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, path);

    const json = try pocket.metadata(cid, "cdk:build") orelse return error.MissingMetadata;
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(BuildMetadata, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(cdk.version, parsed.value.version);
    try std.testing.expectEqual(profiling, parsed.value.profiling);
    try std.testing.expect(parsed.value.dev_access.object.contains("controllers"));
}

test "both builds carry cdk:build metadata" {
    try expectBuildMetadata("zig-out/bin/compute.wasm", false);
    try expectBuildMetadata("zig-out/bin/compute_profiling.wasm", true);
}

test "only controllers may call the profiling endpoints" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deployProfiling(&pocket);

    const stranger = raw(&pocket, cid).as(cdk.principal.canisterId(42));
    const query = try stranger.expectReject(.query, "__get_instructions", {});
    defer query.deinit();
    try std.testing.expect(std.mem.indexOf(u8, query.value.message, "dev endpoints") != null);
    const update = try stranger.expectReject(.update, "__set_profiling", "\x01\x00");
    defer update.deinit();

    const count = try raw(&pocket, cid).query(i64, "__get_instructions", {});
    defer count.deinit();
}

test "the plain build exports no profiling endpoints" {
    var pocket = try initPic();
    defer pocket.deinit();
    const cid = try deploy(&pocket, "zig-out/bin/compute.wasm");

    const canister = raw(&pocket, cid);
    const reject = try canister.expectReject(.update, "__set_profiling", "\x01\x00");
    defer reject.deinit();
    const twin = try canister.expectReject(.update, "__profile_get_counter", {});
    defer twin.deinit();
}
