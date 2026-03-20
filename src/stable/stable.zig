pub const memory = @import("memory.zig");
pub const allocator = @import("allocator.zig");
pub const log = @import("log.zig");

pub const StableMemoryError = memory.StableMemoryError;
pub const wasm_page_size = memory.wasm_page_size;

// Re-export the default (IC-backed) types for convenience.
pub const StableAllocator = allocator.StableAllocator;
pub const StableLog = log.StableLog;

// Re-export the memory read/write/size/grow functions.
pub const size = memory.size;
pub const grow = memory.grow;
pub const read = memory.read;
pub const write = memory.write;
pub const Writer = memory.Writer;
pub const Reader = memory.Reader;

test {
    _ = allocator;
    _ = log;
}
