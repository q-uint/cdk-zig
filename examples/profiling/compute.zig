const std = @import("std");
const cdk = @import("cdk");

var counter: u32 = 0;
var history: std.ArrayList(u32) = .empty;

fn init() void {
    counter = 0;
}

fn compute() void {
    var acc = parseInput();
    acc = process(acc);

    // Manual profiling example: instrument a small inline section.
    cdk.profiling.enter("commit");
    counter = acc;
    history.appendNTimes(cdk.persistent, acc, 256) catch cdk.trap("out of memory");
    cdk.profiling.exit("commit");

    cdk.replyRaw("");
}

fn parseInput() u32 {
    const s = cdk.profiling.section("parse_input");
    defer s.end();

    var acc: u32 = 0;
    for (0..500) |i| {
        acc +%= @as(u32, @intCast(i)) *% 3;
    }
    return acc;
}

fn process(input: u32) u32 {
    const s = cdk.profiling.section("process");
    defer s.end();

    var acc = input;
    acc = validate(acc);
    acc = transform(acc);
    acc = persist(acc);
    return acc;
}

fn validate(acc: u32) u32 {
    const s = cdk.profiling.section("validate");
    defer s.end();

    var result = acc;
    for (0..300) |i| {
        result +%= @as(u32, @intCast(i)) *% 7;
    }
    return result;
}

fn transform(acc: u32) u32 {
    const s = cdk.profiling.section("transform");
    defer s.end();

    var result = acc;
    for (0..1000) |i| {
        result +%= @as(u32, @intCast(i)) *% 13;
    }

    // Manual profiling example: instrument a sub-section.
    cdk.profiling.enter("encode");
    for (0..200) |i| {
        result +%= @as(u32, @intCast(i)) *% 17;
    }
    cdk.profiling.exit("encode");

    return result;
}

fn persist(acc: u32) u32 {
    const s = cdk.profiling.section("persist");
    defer s.end();

    // Grow stable memory and write data to exercise stable memory tracking.
    _ = cdk.stableGrow(2);
    const bytes = @import("std").mem.toBytes(acc);
    cdk.stableWrite(0, &bytes);

    // Write a second region to burn more stable ops.
    _ = cdk.stableGrow(1);
    cdk.stableWrite(64 * 1024, &bytes);

    return acc;
}

fn getCounter() u32 {
    const s = cdk.profiling.section("read_counter");
    defer s.end();
    return counter;
}

// Fails when `fail` is nonzero. Its section still closes, since `end` is
// deferred.
fn check(fail: u8) !u32 {
    const s = cdk.profiling.section("verify");
    defer s.end();
    try mayFail(fail != 0);
    return counter;
}

fn mayFail(fail: bool) !void {
    if (fail) return error.CheckFailed;
}

comptime {
    cdk.init(init);
    cdk.update(compute, "compute");
    cdk.update(check, "check");
    cdk.query(getCounter, "get_counter");
}
