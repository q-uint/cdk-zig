/// In-memory backend that implements the same interface as `memory.zig`
/// (the IC stable64 API wrapper). Provides a fixed-size byte array as
/// a stand-in for stable memory so that the allocator and data
/// structures can be tested on native targets without the IC runtime.
///
/// Call `reset()` at the start of each test to clear all state.
const memory = @import("memory.zig");

const wasm_page_size = memory.wasm_page_size;

/// Maximum number of 64 KiB pages available in the test backend.
pub const page_count = 16;
const total = page_count * wasm_page_size;

var data: [total]u8 = [_]u8{0} ** total;
/// Current number of allocated pages (mirrors `stable64_size`).
pub var pages: u64 = 0;

/// Zero all data and reset the page counter.
pub fn reset() void {
    @memset(&data, 0);
    pages = 0;
}

pub fn size() u64 {
    return pages;
}

pub fn grow(n: u64) memory.StableMemoryError!u64 {
    const old = pages;
    if (old + n > page_count) return memory.StableMemoryError.OutOfMemory;
    pages += n;
    return old;
}

pub fn read(offset: u64, buf: []u8) void {
    const off: usize = @intCast(offset);
    @memcpy(buf, data[off..][0..buf.len]);
}

pub fn write(offset: u64, buf: []const u8) void {
    const off: usize = @intCast(offset);
    @memcpy(data[off..][0..buf.len], buf);
}
