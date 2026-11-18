const std = @import("std");
const cdk = @import("cdk");

/// JSON on the wire, by way of std.json. Anything with these two functions is
/// a codec. Both allocate from `a`, which the CDK frees when the message ends.
pub const Json = struct {
    pub fn encode(a: std.mem.Allocator, comptime T: type, value: T) []const u8 {
        return std.json.Stringify.valueAlloc(a, value, .{}) catch @panic("json: out of memory");
    }

    pub fn decode(a: std.mem.Allocator, comptime T: type, bytes: []const u8) T {
        return std.json.parseFromSliceLeaky(T, a, bytes, .{}) catch @panic("json: invalid argument");
    }
};

pub const cdk_codec = Json;

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

var store: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

// The decoded entry only lasts for this message, so what is kept is copied.
fn put(entry: Entry) !u64 {
    const value = try cdk.persistent.dupe(u8, entry.value);
    errdefer cdk.persistent.free(value);

    if (store.getPtr(entry.key)) |slot| {
        cdk.persistent.free(slot.*);
        slot.* = value;
    } else {
        const key = try cdk.persistent.dupe(u8, entry.key);
        errdefer cdk.persistent.free(key);
        try store.put(cdk.persistent, key, value);
    }
    return store.count();
}

fn get(key: []const u8) ![]const u8 {
    return store.get(key) orelse error.NoSuchKey;
}

fn list(scratch: std.mem.Allocator) ![]const Entry {
    const entries = try scratch.alloc(Entry, store.count());
    for (store.keys(), store.values(), entries) |key, value, *entry| {
        entry.* = .{ .key = key, .value = value };
    }
    return entries;
}

// Not every endpoint has to speak JSON. This one overrides the codec.
fn count() u64 {
    return store.count();
}

comptime {
    cdk.update(put, "put");
    cdk.query(get, "get");
    cdk.query(list, "list");
    cdk.queryWith(cdk.RawCodec, count, "count");
}
