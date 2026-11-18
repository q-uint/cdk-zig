const std = @import("std");
const cdk = @import("cdk");

// Raw stable memory API: size, grow, write, read.

fn getSize() u64 {
    return cdk.stableSize();
}

fn grow(pages: u64) u64 {
    return cdk.stableGrow(pages);
}

fn write() void {
    const arg = cdk.argData();
    if (arg.len < 8) {
        cdk.reject("expected offset (u64) + payload");
        return;
    }
    const offset = std.mem.readInt(u64, arg[0..8], .little);
    const payload = arg[8..];
    cdk.stableWrite(offset, payload);
    cdk.replyRaw("");
}

fn read() ![]const u8 {
    const arg = cdk.argData();
    if (arg.len < 16) return error.ExpectedOffsetAndLength;
    const offset = std.mem.readInt(u64, arg[0..8], .little);
    const len = std.mem.readInt(u64, arg[8..16], .little);
    const buf = try cdk.allocator.alloc(u8, @intCast(len));
    cdk.stableRead(offset, buf);
    return buf;
}

// stable.Writer / stable.Reader streaming API.

// Replies with the final offset, so the test knows how much was written.
fn streamWrite(payload: []const u8) !u64 {
    var w = cdk.stable.Writer.init(0);
    // Two halves, to exercise more than one writeSlice.
    const mid = payload.len / 2;
    _ = try w.writeSlice(payload[0..mid]);
    _ = try w.writeSlice(payload[mid..]);
    return w.currentOffset();
}

fn streamRead(len: u64) ![]const u8 {
    var r = cdk.stable.Reader.init(0);
    const buf = try cdk.allocator.alloc(u8, @intCast(len));
    const n = try r.readSlice(buf);
    return buf[0..n];
}

// Pre/post upgrade hooks to test stable memory persistence.

var counter: u32 = 0;

fn init() void {
    counter = 0;
}

fn preUpgrade() void {
    _ = cdk.stableGrow(1);
    cdk.stableWrite(0, std.mem.asBytes(&counter));
}

fn postUpgrade() void {
    var buf: [4]u8 = undefined;
    cdk.stableRead(0, &buf);
    counter = std.mem.readInt(u32, &buf, .little);
}

fn increment() void {
    counter += 1;
    cdk.replyRaw("");
}

fn getCounter() u32 {
    return counter;
}

comptime {
    cdk.init(init);
    cdk.preUpgrade(preUpgrade);
    cdk.postUpgrade(postUpgrade);
    cdk.query(getSize, "get_size");
    cdk.update(grow, "grow");
    cdk.update(write, "write");
    cdk.query(read, "read");
    cdk.update(streamWrite, "stream_write");
    cdk.query(streamRead, "stream_read");
    cdk.update(increment, "increment");
    cdk.query(getCounter, "get_counter");
}
