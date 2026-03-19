const std = @import("std");
const cdk = @import("cdk");

// Raw stable memory API: size, grow, write, read.

fn getSize() void {
    const pages = cdk.stableSize();
    cdk.replyRaw(std.mem.asBytes(&pages));
}

fn grow() void {
    const arg = cdk.argData();
    if (arg.len < 8) {
        cdk.reject("expected 8 bytes (u64 page count)");
        return;
    }
    const n = std.mem.readInt(u64, arg[0..8], .little);
    const old = cdk.stableGrow(n);
    cdk.replyRaw(std.mem.asBytes(&old));
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

fn read() void {
    const arg = cdk.argData();
    if (arg.len < 16) {
        cdk.reject("expected offset (u64) + length (u64)");
        return;
    }
    const offset = std.mem.readInt(u64, arg[0..8], .little);
    const len = std.mem.readInt(u64, arg[8..16], .little);
    const buf = cdk.allocator.alloc(u8, @intCast(len)) catch {
        cdk.reject("alloc failed");
        return;
    };
    cdk.stableRead(offset, buf);
    cdk.replyRaw(buf);
}

// stable.Writer / stable.Reader streaming API.

fn streamWrite() void {
    const arg = cdk.argData();
    var w = cdk.stable.Writer.init(0);
    // Write the payload in two halves to exercise multiple writeSlice calls.
    const mid = arg.len / 2;
    _ = w.writeSlice(arg[0..mid]) catch {
        cdk.reject("write failed");
        return;
    };
    _ = w.writeSlice(arg[mid..]) catch {
        cdk.reject("write failed");
        return;
    };
    // Reply with the final offset so the test knows how many bytes were written.
    const off = w.currentOffset();
    cdk.replyRaw(std.mem.asBytes(&off));
}

fn streamRead() void {
    const arg = cdk.argData();
    if (arg.len < 8) {
        cdk.reject("expected length (u64)");
        return;
    }
    const len = std.mem.readInt(u64, arg[0..8], .little);
    var r = cdk.stable.Reader.init(0);
    const buf = cdk.allocator.alloc(u8, @intCast(len)) catch {
        cdk.reject("alloc failed");
        return;
    };
    const n = r.readSlice(buf) catch {
        cdk.reject("read failed");
        return;
    };
    cdk.replyRaw(buf[0..n]);
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

fn getCounter() void {
    cdk.replyRaw(std.mem.asBytes(&counter));
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
