const cdk = @import("cdk");

pub const cdk_profiling = true;

var counter: u32 = 0;

fn init() void {
    counter = 0;
}

fn compute() void {
    var acc = parseInput();
    acc = process(acc);

    // Manual profiling example: instrument a small inline section.
    cdk.profiling.enter("commit");
    counter = acc;
    cdk.profiling.exit("commit");

    cdk.replyRaw("");
}

fn parseInput() u32 {
    cdk.profiling.enter("parse_input");
    defer cdk.profiling.exit("parse_input");

    var acc: u32 = 0;
    for (0..500) |i| {
        acc +%= @as(u32, @intCast(i)) *% 3;
    }
    return acc;
}

fn process(input: u32) u32 {
    cdk.profiling.enter("process");
    defer cdk.profiling.exit("process");

    var acc = input;
    acc = validate(acc);
    acc = transform(acc);
    acc = persist(acc);
    return acc;
}

fn validate(acc: u32) u32 {
    cdk.profiling.enter("validate");
    defer cdk.profiling.exit("validate");

    var result = acc;
    for (0..300) |i| {
        result +%= @as(u32, @intCast(i)) *% 7;
    }
    return result;
}

fn transform(acc: u32) u32 {
    cdk.profiling.enter("transform");
    defer cdk.profiling.exit("transform");

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
    cdk.profiling.enter("persist");
    defer cdk.profiling.exit("persist");

    // Grow stable memory and write data to exercise stable memory tracking.
    _ = cdk.stableGrow(2);
    const bytes = @import("std").mem.toBytes(acc);
    cdk.stableWrite(0, &bytes);

    // Write a second region to burn more stable ops.
    _ = cdk.stableGrow(1);
    cdk.stableWrite(64 * 1024, &bytes);

    return acc;
}

fn getCounter() void {
    var buf: [4]u8 = undefined;
    @memcpy(&buf, &@import("std").mem.toBytes(counter));
    cdk.replyRaw(&buf);
}

comptime {
    cdk.init(init);
    cdk.update(compute, "compute");
    cdk.query(getCounter, "get_counter");
}
