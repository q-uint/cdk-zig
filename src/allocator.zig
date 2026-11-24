// The allocator used by all CDK internals (cdk.zig, transition.zig, principal.zig, etc.).
//
// Override it by declaring `cdk_allocator` in your root source file:
//
//     pub const cdk_allocator = std.heap.page_allocator;
//
// If not declared, defaults to:
//   - profiling.counting_allocator when cdk_profiling is enabled (wasm)
//   - wasm_allocator on wasm
//   - page_allocator otherwise
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const profiling = @import("profiling.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const default = if (@hasDecl(root, "cdk_allocator"))
    root.cdk_allocator
else if (is_wasm)
    if (profiling.enabled) profiling.counting_allocator else std.heap.wasm_allocator
else
    std.heap.page_allocator;

const options = if (@hasDecl(root, "cdk_options")) root.cdk_options else struct {};

/// Bytes of scratch kept for the next message, so its argument, work and
/// reply share one buffer.
pub const scratch_retain: usize = if (@hasDecl(options, "scratch_retain"))
    options.scratch_retain
else
    64 * 1024;

/// Memory for one message: arguments, replies, call payloads. Freed when the
/// message ends. An update's heap persists, so without this every reply leaks.
pub const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    retain: usize,
    // A message that allocated nothing skips the reset, whose write would
    // dirty a page, which an update pays for.
    allocated: bool = false,

    pub fn init(backing: std.mem.Allocator, retain: usize) Scratch {
        return .{ .arena = .init(backing), .retain = retain };
    }

    pub fn deinit(self: *Scratch) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Scratch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn endMessage(self: *Scratch) void {
        if (!self.allocated) return;
        self.allocated = false;
        _ = self.arena.reset(.{ .retain_with_limit = self.retain });
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn arenaOf(ctx: *anyopaque) std.mem.Allocator {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        return self.arena.allocator();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        const ptr = self.arena.allocator().rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocated = true;
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        return arenaOf(ctx).rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        return arenaOf(ctx).rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        arenaOf(ctx).rawFree(memory, alignment, ret_addr);
    }
};

var message: Scratch = .init(default, scratch_retain);

pub const scratch = message.allocator();

/// Called by the CDK once a message has replied and sent its calls.
pub fn endMessage() void {
    message.endMessage();
}

test "the message after an idle one still resets" {
    var s: Scratch = .init(std.testing.allocator, 1024);
    defer s.deinit();

    const first = try s.allocator().alloc(u8, 16);
    s.endMessage();
    s.endMessage();
    const second = try s.allocator().alloc(u8, 16);
    try std.testing.expectEqual(first.ptr, second.ptr);
}

test "scratch keeps at most its retain limit" {
    var s: Scratch = .init(std.testing.allocator, 256);
    defer s.deinit();

    _ = try s.allocator().alloc(u8, 4096);
    s.endMessage();
    try std.testing.expect(s.arena.queryCapacity() <= 256);
}
