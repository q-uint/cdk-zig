const std = @import("std");
const ic0 = @import("ic0.zig");

pub const wasm_page_size: u64 = 64 * 1024; // 64 KiB

pub const StableMemoryError = error{
    OutOfMemory,
    OutOfBounds,
};

pub fn size() u64 {
    return @intCast(ic0.stable64_size());
}

pub fn grow(new_pages: u64) StableMemoryError!u64 {
    const result: u64 = @intCast(ic0.stable64_grow(@intCast(new_pages)));
    if (result == std.math.maxInt(u64)) return StableMemoryError.OutOfMemory;
    return result;
}

pub fn write(offset: u64, buf: []const u8) void {
    ic0.stable64_write(@intCast(offset), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len));
}

pub fn read(offset: u64, buf: []u8) void {
    ic0.stable64_read(@intCast(@intFromPtr(buf.ptr)), @intCast(offset), @intCast(buf.len));
}

pub const Writer = struct {
    offset: u64 = 0,
    capacity: u64,

    pub fn init(offset: u64) Writer {
        return .{
            .offset = offset,
            .capacity = size(),
        };
    }

    pub fn writeSlice(self: *Writer, buf: []const u8) StableMemoryError!usize {
        const required_bytes = self.offset + buf.len;
        const required_pages = std.math.divCeil(u64, required_bytes, wasm_page_size) catch unreachable;
        if (required_pages > self.capacity) {
            const additional = required_pages - self.capacity;
            const old = grow(additional) catch return StableMemoryError.OutOfMemory;
            self.capacity = old + additional;
        }
        write(self.offset, buf);
        self.offset += buf.len;
        return buf.len;
    }

    pub fn currentOffset(self: Writer) u64 {
        return self.offset;
    }
};

pub const Reader = struct {
    offset: u64 = 0,
    capacity: u64,

    pub fn init(offset: u64) Reader {
        return .{
            .offset = offset,
            .capacity = size(),
        };
    }

    pub fn readSlice(self: *Reader, buf: []u8) StableMemoryError!usize {
        const capacity_bytes = self.capacity * wasm_page_size;
        if (self.offset >= capacity_bytes) return StableMemoryError.OutOfBounds;
        const available = capacity_bytes - self.offset;
        const to_read = @min(buf.len, available);
        if (to_read == 0) return 0;
        read(self.offset, buf[0..to_read]);
        self.offset += to_read;
        return to_read;
    }

    pub fn currentOffset(self: Reader) u64 {
        return self.offset;
    }
};
