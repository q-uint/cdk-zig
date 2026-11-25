const std = @import("std");
const cdk = @import("cdk");

pub const cdk_codec = cdk.CborCodec;

const Entry = struct { name: []const u8, message: []const u8 };
const Entries = cdk.stable.TypedLog(Entry, cdk.CborCodec);
const Times = cdk.stable.log.Log(cdk.stable.memory, 8);

// Pub, so guestbook_inspect.wasm serves them.
pub var entries: Entries = undefined;
pub var times: Times = undefined;

fn open() void {
    const heap = cdk.stable.StableAllocator.init(Entries.header_size + Times.header_size) catch |e|
        cdk.trap(@errorName(e));
    entries = Entries.init(heap, 0) catch |e| cdk.trap(@errorName(e));
    times = Times.init(heap, Entries.header_size) catch |e| cdk.trap(@errorName(e));
}

fn sign(a: std.mem.Allocator, entry: Entry) !u64 {
    _ = try times.append(&std.mem.toBytes(cdk.time()));
    return entries.append(a, entry);
}

comptime {
    cdk.init(open);
    cdk.postUpgrade(open);
    cdk.update(sign, "sign");
}
