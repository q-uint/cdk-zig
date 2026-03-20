const std = @import("std");
const memory = @import("memory.zig");
const sa = @import("allocator.zig");

const wasm_page_size = memory.wasm_page_size;

/// An append-only list of entries in stable memory.
///
/// When `entry_size` is `null`, entries are variable-length blobs.
/// Each blob is individually allocated and an index array provides
/// O(1) random access. The index doubles in capacity when full.
///
/// When `entry_size` is set, entries are fixed-length and stored
/// contiguously with no index overhead. The data region doubles
/// when full.
///
/// All state lives in stable memory and survives canister upgrades.
pub fn Log(comptime Memory: type, comptime entry_size: ?u64) type {
    const Alloc = sa.Allocator(Memory);
    const is_fixed = entry_size != null;
    const fixed_len = entry_size orelse 0;

    return struct {
        alloc: Alloc,
        base: u64,

        const Self = @This();

        pub const header_size: u64 = @sizeOf(Header);
        const initial_capacity: u64 = 64;

        // Variable: each index slot is 16 bytes (offset + len).
        // Fixed: each data slot is fixed_len bytes.
        const slot_size: u64 = if (is_fixed) fixed_len else @sizeOf(IndexEntry);

        const magic_value: u64 = if (is_fixed)
            0x5354_4142_4C4F_4701 // STABLOG\1 (fixed)
        else
            0x5354_4142_4C4F_4700; // STABLOG\0 (variable)

        const Header = extern struct {
            magic_val: u64,
            count: u64,
            region_offset: u64,
            region_capacity: u64,
            _reserved1: u64,
            _reserved2: u64,
        };

        const IndexEntry = extern struct {
            offset: u64,
            len: u64,
        };

        /// Initialize a log with its header at `base`.
        /// `alloc` is used for data and (in variable mode) index allocations.
        /// `base` must not overlap with `alloc`'s managed region.
        pub fn init(alloc: Alloc, base: u64) memory.StableMemoryError!Self {
            var self = Self{ .alloc = alloc, .base = base };

            const cap = Memory.size() * wasm_page_size;
            if (cap >= base + header_size) {
                var buf: [8]u8 = undefined;
                Memory.read(base, &buf);
                if (std.mem.readInt(u64, &buf, .little) == magic_value) {
                    return self;
                }
            }

            const required_pages = std.math.divCeil(
                u64,
                base + header_size,
                wasm_page_size,
            ) catch unreachable;
            const current_pages = Memory.size();
            if (required_pages > current_pages) {
                _ = try Memory.grow(required_pages - current_pages);
            }

            const region_offset = try self.alloc.alloc(initial_capacity * slot_size);

            self.writeHeader(.{
                .magic_val = magic_value,
                .count = 0,
                .region_offset = region_offset,
                .region_capacity = initial_capacity,
                ._reserved1 = 0,
                ._reserved2 = 0,
            });

            return self;
        }

        /// Append an entry. Returns its index.
        ///
        /// Fixed mode: `data` is a pointer to exactly `entry_size` bytes.
        /// Variable mode: `data` is an arbitrary-length slice.
        pub fn append(
            self: *Self,
            data: if (is_fixed) *const [fixed_len]u8 else []const u8,
        ) memory.StableMemoryError!u64 {
            var hdr = self.readHeader();

            if (hdr.count >= hdr.region_capacity) {
                try self.growRegion(&hdr);
            }

            const idx = hdr.count;

            if (is_fixed) {
                if (fixed_len > 0) {
                    Memory.write(hdr.region_offset + idx * fixed_len, data);
                }
            } else {
                const data_offset = try self.alloc.alloc(data.len);
                if (data.len > 0) {
                    Memory.write(data_offset, data);
                }
                writeIndexEntry(hdr.region_offset, idx, .{
                    .offset = data_offset,
                    .len = data.len,
                });
            }

            hdr.count = idx + 1;
            self.writeHeader(hdr);
            return idx;
        }

        /// Read an entry by index.
        ///
        /// Fixed mode: fills `buf` (exactly `entry_size` bytes) and
        /// returns `true`, or `false` if out of range.
        ///
        /// Variable mode: fills `buf` and returns the populated slice,
        /// or `null` if out of range or the buffer is too small.
        pub fn get(
            self: Self,
            index: u64,
            buf: if (is_fixed) *[fixed_len]u8 else []u8,
        ) if (is_fixed) bool else ?[]const u8 {
            const hdr = self.readHeader();

            if (index >= hdr.count) {
                return if (is_fixed) false else null;
            }

            if (is_fixed) {
                if (fixed_len > 0) {
                    Memory.read(hdr.region_offset + index * fixed_len, buf);
                }
                return true;
            } else {
                const ie = readIndexEntry(hdr.region_offset, index);
                if (ie.len == 0) return buf[0..0];
                if (buf.len < ie.len) return null;
                const n: usize = @intCast(ie.len);
                Memory.read(ie.offset, buf[0..n]);
                return buf[0..n];
            }
        }

        /// Returns the byte length of the entry at `index`,
        /// or null if the index is out of range.
        pub fn entrySize(self: Self, index: u64) ?u64 {
            const hdr = self.readHeader();
            if (index >= hdr.count) return null;
            if (is_fixed) return fixed_len;
            return readIndexEntry(hdr.region_offset, index).len;
        }

        /// Returns the number of entries in the log.
        pub fn len(self: Self) u64 {
            return self.readHeader().count;
        }

        fn growRegion(self: *Self, hdr: *Header) memory.StableMemoryError!void {
            const new_cap = hdr.region_capacity * 2;
            const new_region = try self.alloc.alloc(new_cap * slot_size);

            const copy_bytes = hdr.count * slot_size;
            var copied: u64 = 0;
            while (copied < copy_bytes) {
                var buf: [512]u8 = undefined;
                const chunk: usize = @intCast(@min(512, copy_bytes - copied));
                Memory.read(hdr.region_offset + copied, buf[0..chunk]);
                Memory.write(new_region + copied, buf[0..chunk]);
                copied += chunk;
            }

            self.alloc.free(hdr.region_offset);
            hdr.region_offset = new_region;
            hdr.region_capacity = new_cap;
        }

        fn readHeader(self: Self) Header {
            var buf: [header_size]u8 = undefined;
            Memory.read(self.base, &buf);
            return .{
                .magic_val = std.mem.readInt(u64, buf[0..8], .little),
                .count = std.mem.readInt(u64, buf[8..16], .little),
                .region_offset = std.mem.readInt(u64, buf[16..24], .little),
                .region_capacity = std.mem.readInt(u64, buf[24..32], .little),
                ._reserved1 = std.mem.readInt(u64, buf[32..40], .little),
                ._reserved2 = std.mem.readInt(u64, buf[40..48], .little),
            };
        }

        fn writeHeader(self: Self, hdr: Header) void {
            var buf: [header_size]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], hdr.magic_val, .little);
            std.mem.writeInt(u64, buf[8..16], hdr.count, .little);
            std.mem.writeInt(u64, buf[16..24], hdr.region_offset, .little);
            std.mem.writeInt(u64, buf[24..32], hdr.region_capacity, .little);
            std.mem.writeInt(u64, buf[32..40], hdr._reserved1, .little);
            std.mem.writeInt(u64, buf[40..48], hdr._reserved2, .little);
            Memory.write(self.base, &buf);
        }

        fn readIndexEntry(region_base: u64, idx: u64) IndexEntry {
            const sz = @sizeOf(IndexEntry);
            var buf: [sz]u8 = undefined;
            Memory.read(region_base + idx * sz, &buf);
            return .{
                .offset = std.mem.readInt(u64, buf[0..8], .little),
                .len = std.mem.readInt(u64, buf[8..16], .little),
            };
        }

        fn writeIndexEntry(region_base: u64, idx: u64, ie: IndexEntry) void {
            const sz = @sizeOf(IndexEntry);
            var buf: [sz]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], ie.offset, .little);
            std.mem.writeInt(u64, buf[8..16], ie.len, .little);
            Memory.write(region_base + idx * sz, &buf);
        }
    };
}

/// Default variable-length stable log using the IC stable64 API.
pub const StableLog = Log(memory, null);

const testing_memory = @import("testing.zig");
const TestAlloc = sa.Allocator(testing_memory);
const VarLog = Log(testing_memory, null);
const FixedLog32 = Log(testing_memory, 32);

fn initVar() !struct { alloc: TestAlloc, log: VarLog } {
    testing_memory.reset();
    const alloc = try TestAlloc.init(VarLog.header_size);
    const log = try VarLog.init(alloc, 0);
    return .{ .alloc = alloc, .log = log };
}

fn initFixed() !struct { alloc: TestAlloc, log: FixedLog32 } {
    testing_memory.reset();
    const alloc = try TestAlloc.init(FixedLog32.header_size);
    const log = try FixedLog32.init(alloc, 0);
    return .{ .alloc = alloc, .log = log };
}

test "var: append and get" {
    var s = try initVar();

    const idx0 = try s.log.append("hello");
    const idx1 = try s.log.append("world");

    try std.testing.expectEqual(@as(u64, 0), idx0);
    try std.testing.expectEqual(@as(u64, 1), idx1);
    try std.testing.expectEqual(@as(u64, 2), s.log.len());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", s.log.get(0, &buf).?);
    try std.testing.expectEqualStrings("world", s.log.get(1, &buf).?);
}

test "var: get out of range returns null" {
    var s = try initVar();
    var buf: [64]u8 = undefined;
    try std.testing.expect(s.log.get(0, &buf) == null);
    try std.testing.expect(s.log.get(99, &buf) == null);
}

test "var: get with buffer too small returns null" {
    var s = try initVar();
    _ = try s.log.append("hello world");
    var small: [5]u8 = undefined;
    try std.testing.expect(s.log.get(0, &small) == null);
}

test "var: entrySize" {
    var s = try initVar();

    _ = try s.log.append("abc");
    _ = try s.log.append("defgh");
    _ = try s.log.append("");

    try std.testing.expectEqual(@as(u64, 3), s.log.entrySize(0).?);
    try std.testing.expectEqual(@as(u64, 5), s.log.entrySize(1).?);
    try std.testing.expectEqual(@as(u64, 0), s.log.entrySize(2).?);
    try std.testing.expect(s.log.entrySize(3) == null);
}

test "var: empty entry" {
    var s = try initVar();

    const idx = try s.log.append("");
    try std.testing.expectEqual(@as(u64, 0), idx);
    try std.testing.expectEqual(@as(u64, 1), s.log.len());

    var buf: [64]u8 = undefined;
    const entry = s.log.get(0, &buf).?;
    try std.testing.expectEqual(@as(usize, 0), entry.len);
}

test "var: init is idempotent" {
    var s = try initVar();

    _ = try s.log.append("persist");
    try std.testing.expectEqual(@as(u64, 1), s.log.len());

    var log2 = try VarLog.init(s.alloc, 0);
    try std.testing.expectEqual(@as(u64, 1), log2.len());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("persist", log2.get(0, &buf).?);
}

test "var: index grows beyond initial capacity" {
    var s = try initVar();

    var idx: u64 = 0;
    while (idx < 80) : (idx += 1) {
        try std.testing.expectEqual(idx, try s.log.append("entry"));
    }

    try std.testing.expectEqual(@as(u64, 80), s.log.len());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("entry", s.log.get(0, &buf).?);
    try std.testing.expectEqualStrings("entry", s.log.get(79, &buf).?);
}

test "var: many variable-size entries" {
    var s = try initVar();

    _ = try s.log.append("short");
    _ = try s.log.append("a medium length string for testing");
    _ = try s.log.append("x" ** 200);
    _ = try s.log.append("");
    _ = try s.log.append("final");

    try std.testing.expectEqual(@as(u64, 5), s.log.len());

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("short", s.log.get(0, &buf).?);
    try std.testing.expectEqualStrings(
        "a medium length string for testing",
        s.log.get(1, &buf).?,
    );
    try std.testing.expectEqual(@as(usize, 200), s.log.get(2, &buf).?.len);
    try std.testing.expectEqual(@as(usize, 0), s.log.get(3, &buf).?.len);
    try std.testing.expectEqualStrings("final", s.log.get(4, &buf).?);
}

test "fixed: append and get" {
    var s = try initFixed();

    var entry1 = [_]u8{0} ** 32;
    @memcpy(entry1[0..5], "hello");

    var entry2 = [_]u8{0} ** 32;
    @memcpy(entry2[0..5], "world");

    const idx0 = try s.log.append(&entry1);
    const idx1 = try s.log.append(&entry2);

    try std.testing.expectEqual(@as(u64, 0), idx0);
    try std.testing.expectEqual(@as(u64, 1), idx1);
    try std.testing.expectEqual(@as(u64, 2), s.log.len());

    var buf: [32]u8 = undefined;
    try std.testing.expect(s.log.get(0, &buf));
    try std.testing.expectEqualSlices(u8, &entry1, &buf);

    try std.testing.expect(s.log.get(1, &buf));
    try std.testing.expectEqualSlices(u8, &entry2, &buf);
}

test "fixed: get out of range returns false" {
    var s = try initFixed();
    var buf: [32]u8 = undefined;
    try std.testing.expect(!s.log.get(0, &buf));
    try std.testing.expect(!s.log.get(99, &buf));
}

test "fixed: entrySize is constant" {
    var s = try initFixed();

    const entry = [_]u8{0xAA} ** 32;
    _ = try s.log.append(&entry);

    try std.testing.expectEqual(@as(u64, 32), s.log.entrySize(0).?);
    try std.testing.expect(s.log.entrySize(1) == null);
}

test "fixed: init is idempotent" {
    var s = try initFixed();

    const entry = [_]u8{0xBB} ** 32;
    _ = try s.log.append(&entry);

    var log2 = try FixedLog32.init(s.alloc, 0);
    try std.testing.expectEqual(@as(u64, 1), log2.len());

    var buf: [32]u8 = undefined;
    try std.testing.expect(log2.get(0, &buf));
    try std.testing.expectEqualSlices(u8, &entry, &buf);
}

test "fixed: data region grows beyond initial capacity" {
    var s = try initFixed();

    var idx: u64 = 0;
    while (idx < 80) : (idx += 1) {
        var entry: [32]u8 = undefined;
        @memset(&entry, @intCast(idx & 0xFF));
        try std.testing.expectEqual(idx, try s.log.append(&entry));
    }

    try std.testing.expectEqual(@as(u64, 80), s.log.len());

    var buf: [32]u8 = undefined;

    try std.testing.expect(s.log.get(0, &buf));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0), b);

    try std.testing.expect(s.log.get(79, &buf));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 79), b);
}
