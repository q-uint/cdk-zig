const std = @import("std");
const memory = @import("memory.zig");
const sa = @import("allocator.zig");
const layout = @import("layout.zig");

/// An append-only list of entries in stable memory.
///
/// Entries live in segments. Segment `c` holds `base_len << c` entries, is
/// allocated when its first entry is appended, and never moves. Appending
/// never copies, and entry `i` is found with bit arithmetic.
///
/// When `entry_size` is set, entries are fixed-length and stored in the
/// segments. When it is `null`, entries are blobs and the segments index
/// them. Blobs are bump-allocated from chunks, since a log never frees.
///
/// All state lives in stable memory and survives canister upgrades.
pub fn Log(comptime Memory: type, comptime entry_size: ?u64) type {
    if (entry_size) |n| if (n == 0) @compileError("entry_size must not be 0");

    const Alloc = sa.Allocator(Memory);
    const is_fixed = entry_size != null;
    const fixed_len = entry_size orelse 0;

    return struct {
        alloc: Alloc,
        base: u64,

        const Self = @This();

        pub const header_size: u64 = @sizeOf(Header);

        const base_len: u64 = 64;
        const max_segments = 64;
        // A blob this large or larger gets an allocation of its own.
        const chunk_size: u64 = memory.wasm_page_size;

        const slot_size: u64 = if (is_fixed) fixed_len else @sizeOf(IndexEntry);

        const Header = extern struct {
            magic: u64,
            count: u64,
            // The free span of the current blob chunk.
            chunk_next: u64,
            chunk_end: u64,
            // 0 until allocated.
            segments: [max_segments]u64,
        };

        const IndexEntry = extern struct {
            offset: u64,
            len: u64,
        };

        const magic = layout.fingerprint(
            "stable.Log",
            1,
            &.{ Header, IndexEntry },
            std.fmt.comptimePrint("entry_size={?d},base_len={d}", .{ entry_size, base_len }),
        );

        /// Open the log whose header is at `base`, or create one there.
        /// `alloc` provides segments and blobs. `base` must not overlap with
        /// `alloc`'s managed region.
        pub fn init(alloc: Alloc, base: u64) layout.Error!Self {
            const self = Self{ .alloc = alloc, .base = base };
            if (try layout.open(Memory, base, magic, header_size)) return self;

            var hdr = std.mem.zeroes(Header);
            hdr.magic = magic;
            layout.store(Memory, Header, base, hdr);
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
            const idx = self.load("count");
            const at = try self.claimSlot(idx);

            if (is_fixed) {
                Memory.write(at, data);
            } else {
                const offset = try self.reserve(data.len);
                if (data.len > 0) Memory.write(offset, data);
                layout.store(Memory, IndexEntry, at, .{ .offset = offset, .len = data.len });
            }

            self.store("count", idx + 1);
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
            if (index >= self.len()) {
                return if (is_fixed) false else null;
            }

            const at = self.slotAt(index);
            if (is_fixed) {
                Memory.read(at, buf);
                return true;
            } else {
                const ie = layout.load(Memory, IndexEntry, at);
                if (ie.len == 0) return buf[0..0];
                if (buf.len < ie.len) return null;
                const n: usize = @intCast(ie.len);
                Memory.read(ie.offset, buf[0..n]);
                return buf[0..n];
            }
        }

        /// Read consecutive entries from `start` into `buf`, with one read
        /// per segment they span. Returns the entries read, fewer than `buf`
        /// holds when the log ends first.
        pub fn getRange(self: Self, start: u64, buf: [][fixed_len]u8) [][fixed_len]u8 {
            if (!is_fixed) @compileError("getRange needs a fixed entry_size");

            const count = self.len();
            if (start >= count) return buf[0..0];
            const n: usize = @intCast(@min(@as(u64, buf.len), count - start));

            var done: usize = 0;
            while (done < n) {
                const loc = locate(start + done);
                const room = (base_len << loc.segment) - loc.index;
                const take: usize = @intCast(@min(room, @as(u64, n - done)));
                Memory.read(
                    self.slotAt(start + done),
                    std.mem.sliceAsBytes(buf[done..][0..take]),
                );
                done += take;
            }
            return buf[0..n];
        }

        /// Returns the byte length of the entry at `index`,
        /// or null if the index is out of range.
        pub fn entrySize(self: Self, index: u64) ?u64 {
            if (index >= self.len()) return null;
            if (is_fixed) return fixed_len;
            return layout.load(Memory, IndexEntry, self.slotAt(index)).len;
        }

        /// Returns the number of entries in the log.
        pub fn len(self: Self) u64 {
            return self.load("count");
        }

        const Slot = struct { segment: u6, index: u64 };

        fn locate(i: u64) Slot {
            const c = std.math.log2_int(u64, i / base_len + 1);
            return .{ .segment = c, .index = i - base_len * ((@as(u64, 1) << c) - 1) };
        }

        fn slotAt(self: Self, i: u64) u64 {
            const loc = locate(i);
            return layout.load(Memory, u64, self.segmentField(loc.segment)) + loc.index * slot_size;
        }

        // Like slotAt, but allocates the segment on its first entry.
        fn claimSlot(self: *Self, i: u64) memory.StableMemoryError!u64 {
            const loc = locate(i);
            const field = self.segmentField(loc.segment);
            var segment = layout.load(Memory, u64, field);
            if (segment == 0) {
                const bytes = std.math.mul(u64, base_len << loc.segment, slot_size) catch
                    return error.OutOfMemory;
                segment = try self.alloc.alloc(bytes);
                layout.store(Memory, u64, field, segment);
            }
            return segment + loc.index * slot_size;
        }

        fn reserve(self: *Self, n: u64) memory.StableMemoryError!u64 {
            if (n == 0) return 0;
            if (n >= chunk_size) return self.alloc.alloc(n);

            const next = self.load("chunk_next");
            if (n <= self.load("chunk_end") - next) {
                self.store("chunk_next", next + n);
                return next;
            }

            const chunk = try self.alloc.alloc(chunk_size);
            self.store("chunk_next", chunk + n);
            self.store("chunk_end", chunk + chunk_size);
            return chunk;
        }

        fn segmentField(self: Self, c: u6) u64 {
            return self.base + @offsetOf(Header, "segments") + @as(u64, c) * 8;
        }

        fn load(self: Self, comptime field: []const u8) u64 {
            return layout.load(Memory, u64, self.base + @offsetOf(Header, field));
        }

        fn store(self: Self, comptime field: []const u8, value: u64) void {
            layout.store(Memory, u64, self.base + @offsetOf(Header, field), value);
        }
    };
}

/// Default variable-length stable log using the IC stable64 API.
pub const StableLog = Log(memory, null);

const testing_memory = @import("testing.zig");
const TestAlloc = sa.Allocator(testing_memory);
const VarLog = Log(testing_memory, null);
const FixedLog32 = Log(testing_memory, 32);
const FixedLog64 = Log(testing_memory, 64);
// Each entry holds its own index, so reads can check they got the right one.
const IndexLog = Log(testing_memory, 8);

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

fn initIndexLog(n: u64) !IndexLog {
    testing_memory.reset();
    var log = try IndexLog.init(try TestAlloc.init(IndexLog.header_size), 0);
    var i: u64 = 0;
    while (i < n) : (i += 1) _ = try log.append(&std.mem.toBytes(i));
    return log;
}

test "locate" {
    try std.testing.expectEqual(FixedLog32.Slot{ .segment = 0, .index = 0 }, FixedLog32.locate(0));
    try std.testing.expectEqual(FixedLog32.Slot{ .segment = 0, .index = 63 }, FixedLog32.locate(63));
    try std.testing.expectEqual(FixedLog32.Slot{ .segment = 1, .index = 0 }, FixedLog32.locate(64));
    try std.testing.expectEqual(FixedLog32.Slot{ .segment = 1, .index = 127 }, FixedLog32.locate(191));
    try std.testing.expectEqual(FixedLog32.Slot{ .segment = 2, .index = 0 }, FixedLog32.locate(192));
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

test "var: index grows beyond the first segment" {
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

test "var: small blobs are packed into one chunk" {
    var s = try initVar();

    _ = try s.log.append("hello");
    _ = try s.log.append("world");

    const first = layout.load(testing_memory, VarLog.IndexEntry, s.log.slotAt(0));
    const second = layout.load(testing_memory, VarLog.IndexEntry, s.log.slotAt(1));
    try std.testing.expectEqual(first.offset + 5, second.offset);
}

test "var: a blob larger than a chunk" {
    var s = try initVar();

    _ = try s.log.append("before");
    const big: [VarLog.chunk_size + 1]u8 = @splat('b');
    _ = try s.log.append(&big);
    _ = try s.log.append("after");

    var buf: [VarLog.chunk_size + 1]u8 = undefined;
    try std.testing.expectEqualStrings("before", s.log.get(0, &buf).?);
    try std.testing.expectEqualSlices(u8, &big, s.log.get(1, &buf).?);
    try std.testing.expectEqualStrings("after", s.log.get(2, &buf).?);
}

test "var: many variable-size entries" {
    var s = try initVar();

    _ = try s.log.append("short");
    _ = try s.log.append("a medium length string for testing");
    const long: [200]u8 = @splat('x');
    _ = try s.log.append(&long);
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

    var entry1: [32]u8 = @splat(0);
    @memcpy(entry1[0..5], "hello");

    var entry2: [32]u8 = @splat(0);
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

    const entry: [32]u8 = @splat(0xAA);
    _ = try s.log.append(&entry);

    try std.testing.expectEqual(@as(u64, 32), s.log.entrySize(0).?);
    try std.testing.expect(s.log.entrySize(1) == null);
}

test "fixed: init is idempotent" {
    var s = try initFixed();

    const entry: [32]u8 = @splat(0xBB);
    _ = try s.log.append(&entry);

    var log2 = try FixedLog32.init(s.alloc, 0);
    try std.testing.expectEqual(@as(u64, 1), log2.len());

    var buf: [32]u8 = undefined;
    try std.testing.expect(log2.get(0, &buf));
    try std.testing.expectEqualSlices(u8, &entry, &buf);
}

test "fixed: segments never move" {
    var log = try initIndexLog(1);
    const first = log.slotAt(0);

    var i: u64 = 1;
    while (i < 300) : (i += 1) _ = try log.append(&std.mem.toBytes(i));

    try std.testing.expectEqual(first, log.slotAt(0));
    i = 0;
    while (i < 300) : (i += 1) {
        var buf: [8]u8 = undefined;
        try std.testing.expect(log.get(i, &buf));
        try std.testing.expectEqual(i, std.mem.bytesToValue(u64, &buf));
    }
}

test "fixed: getRange spans segments" {
    const log = try initIndexLog(300);

    // 50..250 crosses from segment 0 through 1 into 2.
    var buf: [200][8]u8 = undefined;
    const got = log.getRange(50, &buf);
    try std.testing.expectEqual(@as(usize, 200), got.len);
    for (got, 50..) |entry, i| try std.testing.expectEqual(@as(u64, i), std.mem.bytesToValue(u64, &entry));

    // Clipped at the end of the log.
    try std.testing.expectEqual(@as(usize, 10), log.getRange(290, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), log.getRange(300, &buf).len);
}

test "init refuses another layout" {
    var s = try initFixed();
    const entry: [32]u8 = @splat(1);
    _ = try s.log.append(&entry);

    try std.testing.expectError(error.LayoutMismatch, FixedLog64.init(s.alloc, 0));
    try std.testing.expectError(error.LayoutMismatch, VarLog.init(s.alloc, 0));
}
