const std = @import("std");
const memory = @import("memory.zig");

const wasm_page_size = memory.wasm_page_size;

/// A general-purpose allocator for IC stable memory.
///
/// Manages allocations within stable memory, returning u64 offsets
/// since stable memory is outside the WASM linear address space.
/// Use `read` and `write` to access data at allocated offsets.
///
/// The allocator state is stored in stable memory itself, so it
/// persists across canister upgrades without any serialization.
///
/// Generic over `Memory` to allow testing with an in-memory backend.
/// For production use, pass `@import("memory.zig")`.
pub fn Allocator(comptime Memory: type) type {
    return struct {
        base: u64,

        const Self = @This();

        // All allocations and block headers are aligned to this boundary.
        pub const min_align: u64 = 16;
        pub const global_header_size: u64 = @sizeOf(GlobalHeader);
        pub const block_header_size: u64 = @sizeOf(BlockHeader);

        const magic_value: u64 = 0x5354_4142_414C_4C43; // STABALLC

        const GlobalHeader = extern struct {
            magic_val: u64,
            next_offset: u64,
            free_list_head: u64,
            _reserved: u64,
        };

        const BlockHeader = extern struct {
            size: u64,
            next_free: u64,
        };

        /// Initialize an allocator rooted at `base` in stable memory.
        ///
        /// If the region was previously initialized (magic present),
        /// restores the existing state. Otherwise writes a fresh header.
        pub fn init(base: u64) memory.StableMemoryError!Self {
            const self = Self{ .base = base };

            const capacity = Memory.size() * wasm_page_size;
            if (capacity >= base + global_header_size) {
                var buf: [8]u8 = undefined;
                Memory.read(base, &buf);
                if (std.mem.readInt(u64, &buf, .little) == magic_value) {
                    return self;
                }
            }

            const required_pages = std.math.divCeil(
                u64,
                base + global_header_size,
                wasm_page_size,
            ) catch unreachable;
            const current_pages = Memory.size();
            if (required_pages > current_pages) {
                _ = try Memory.grow(required_pages - current_pages);
            }

            self.writeGlobalHeader(.{
                .magic_val = magic_value,
                .next_offset = base + global_header_size,
                .free_list_head = 0,
                ._reserved = 0,
            });

            return self;
        }

        /// Allocate `len` bytes. Returns the stable memory offset of the
        /// allocated region, or 0 if `len` is 0.
        pub fn alloc(self: *Self, len: u64) memory.StableMemoryError!u64 {
            if (len == 0) return 0;

            const padded = std.mem.alignForward(u64, len, min_align);
            var gh = self.readGlobalHeader();

            // First-fit search through the free list.
            var prev: u64 = 0;
            var cur = gh.free_list_head;
            while (cur != 0) {
                const bh = readBlockHeader(cur);
                if (bh.size >= padded) {
                    if (prev == 0) {
                        gh.free_list_head = bh.next_free;
                    } else {
                        var pbh = readBlockHeader(prev);
                        pbh.next_free = bh.next_free;
                        writeBlockHeader(prev, pbh);
                    }
                    writeBlockHeader(cur, .{ .size = bh.size, .next_free = 0 });
                    self.writeGlobalHeader(gh);
                    return cur + block_header_size;
                }
                prev = cur;
                cur = bh.next_free;
            }

            // Bump allocate.
            const block_start = std.mem.alignForward(u64, gh.next_offset, min_align);
            const data_start = block_start + block_header_size;
            const new_next = data_start + padded;

            const required_pages = std.math.divCeil(u64, new_next, wasm_page_size) catch unreachable;
            const current_pages = Memory.size();
            if (required_pages > current_pages) {
                _ = try Memory.grow(required_pages - current_pages);
            }

            writeBlockHeader(block_start, .{ .size = padded, .next_free = 0 });
            gh.next_offset = new_next;
            self.writeGlobalHeader(gh);

            return data_start;
        }

        /// Free a previously allocated region. The offset must have been
        /// returned by `alloc`.
        pub fn free(self: *Self, offset: u64) void {
            if (offset == 0) return;

            const block_start = offset - block_header_size;
            var gh = self.readGlobalHeader();
            var bh = readBlockHeader(block_start);

            bh.next_free = gh.free_list_head;
            writeBlockHeader(block_start, bh);
            gh.free_list_head = block_start;
            self.writeGlobalHeader(gh);
        }

        /// Read data from stable memory at `offset` into `buf`.
        pub fn read(offset: u64, buf: []u8) void {
            Memory.read(offset, buf);
        }

        /// Write `data` to stable memory at `offset`.
        pub fn write(offset: u64, data: []const u8) void {
            Memory.write(offset, data);
        }

        fn readGlobalHeader(self: Self) GlobalHeader {
            var buf: [global_header_size]u8 = undefined;
            Memory.read(self.base, &buf);
            return .{
                .magic_val = std.mem.readInt(u64, buf[0..8], .little),
                .next_offset = std.mem.readInt(u64, buf[8..16], .little),
                .free_list_head = std.mem.readInt(u64, buf[16..24], .little),
                ._reserved = std.mem.readInt(u64, buf[24..32], .little),
            };
        }

        fn writeGlobalHeader(self: Self, gh: GlobalHeader) void {
            var buf: [global_header_size]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], gh.magic_val, .little);
            std.mem.writeInt(u64, buf[8..16], gh.next_offset, .little);
            std.mem.writeInt(u64, buf[16..24], gh.free_list_head, .little);
            std.mem.writeInt(u64, buf[24..32], gh._reserved, .little);
            Memory.write(self.base, &buf);
        }

        fn readBlockHeader(offset: u64) BlockHeader {
            var buf: [block_header_size]u8 = undefined;
            Memory.read(offset, &buf);
            return .{
                .size = std.mem.readInt(u64, buf[0..8], .little),
                .next_free = std.mem.readInt(u64, buf[8..16], .little),
            };
        }

        fn writeBlockHeader(offset: u64, bh: BlockHeader) void {
            var buf: [block_header_size]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], bh.size, .little);
            std.mem.writeInt(u64, buf[8..16], bh.next_free, .little);
            Memory.write(offset, &buf);
        }
    };
}

/// Default stable memory allocator using the IC stable64 API.
pub const StableAllocator = Allocator(memory);

const testing_memory = @import("testing.zig");
const TestAllocator = Allocator(testing_memory);

test "init creates header" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);
    const gh = a.readGlobalHeader();
    try std.testing.expectEqual(TestAllocator.magic_value, gh.magic_val);
    try std.testing.expectEqual(TestAllocator.global_header_size, gh.next_offset);
    try std.testing.expectEqual(@as(u64, 0), gh.free_list_head);
}

test "init is idempotent" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);
    const off = try a.alloc(64);
    try std.testing.expect(off != 0);

    // Re-init should detect existing header and preserve state.
    var b = try TestAllocator.init(0);
    const gh = b.readGlobalHeader();
    try std.testing.expect(gh.next_offset > TestAllocator.global_header_size);
}

test "alloc and read/write" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);

    const off = try a.alloc(19);
    try std.testing.expect(off != 0);

    const msg = "hello stable memory";
    TestAllocator.write(off, msg);

    var buf: [19]u8 = undefined;
    TestAllocator.read(off, &buf);
    try std.testing.expectEqualStrings(msg, &buf);
}

test "sequential allocations do not overlap" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);

    const off1 = try a.alloc(100);
    const off2 = try a.alloc(200);
    try std.testing.expect(off2 >= off1 + 100);

    var data1: [100]u8 = undefined;
    @memset(&data1, 0xAA);
    TestAllocator.write(off1, &data1);

    var data2: [200]u8 = undefined;
    @memset(&data2, 0xBB);
    TestAllocator.write(off2, &data2);

    var check1: [100]u8 = undefined;
    TestAllocator.read(off1, &check1);
    for (check1) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);

    var check2: [200]u8 = undefined;
    TestAllocator.read(off2, &check2);
    for (check2) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
}

test "free and reuse" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);

    const off1 = try a.alloc(100);
    _ = try a.alloc(200);

    a.free(off1);

    const off3 = try a.alloc(50);
    try std.testing.expectEqual(off1, off3);
}

test "alloc zero returns zero" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);
    const off = try a.alloc(0);
    try std.testing.expectEqual(@as(u64, 0), off);
}

test "free zero is a no-op" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);
    a.free(0);
}

test "non-zero base offset" {
    testing_memory.reset();

    testing_memory.pages = 1;
    var a = try TestAllocator.init(1024);

    const off = try a.alloc(64);
    try std.testing.expect(off >= 1024 + TestAllocator.global_header_size);

    const msg = "offset base";
    TestAllocator.write(off, msg[0..msg.len]);

    var buf: [msg.len]u8 = undefined;
    TestAllocator.read(off, &buf);
    try std.testing.expectEqualStrings(msg, &buf);
}

test "grows stable memory on demand" {
    testing_memory.reset();

    var a = try TestAllocator.init(0);
    try std.testing.expectEqual(@as(u64, 1), testing_memory.pages);

    _ = try a.alloc(wasm_page_size);
    try std.testing.expect(testing_memory.pages > 1);
}
