// Compile-time opt-in profiling module for flamegraph / cycle cost analysis.
//
// Enable by declaring in your root source file:
//
//     pub const cdk_profiling = true;
//
// When disabled (the default), all functions are no-ops and no endpoints
// are exported. Zero overhead in production.
//
// Each trace entry records three metrics at the point of function
// entry/exit: instruction count, heap bytes (live allocations), and
// stable memory pages. The flamegraph renderer can select which metric
// to render.
//
// When profiling is enabled, the CDK automatically uses a counting
// allocator that tracks live heap bytes. If the user overrides
// cdk_allocator, the heap_bytes metric falls back to WASM linear
// memory pages instead.

const std = @import("std");
const root = @import("root");
const cdk = @import("cdk.zig");
const alloc = @import("allocator.zig").default;

pub const enabled = @hasDecl(root, "cdk_profiling") and root.cdk_profiling;

// Counting allocator that wraps the default WASM allocator and tracks
// the number of live heap bytes. Use as cdk_allocator to get per-function
// heap cost in flamegraphs.
pub var heap_bytes: i64 = 0;

const has_counting_allocator = alloc.vtable == counting_allocator.vtable;

fn countingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    const ptr = std.heap.wasm_allocator.rawAlloc(len, alignment, ret_addr);
    if (ptr != null) {
        heap_bytes += @intCast(len);
    }
    return ptr;
}

fn countingResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    const ok = std.heap.wasm_allocator.rawResize(buf, alignment, new_len, ret_addr);
    if (ok) {
        heap_bytes += @as(i64, @intCast(new_len)) - @as(i64, @intCast(buf.len));
    }
    return ok;
}

fn countingRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    const ptr = std.heap.wasm_allocator.rawRemap(buf, alignment, new_len, ret_addr);
    if (ptr != null) {
        heap_bytes += @as(i64, @intCast(new_len)) - @as(i64, @intCast(buf.len));
    }
    return ptr;
}

fn countingFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    std.heap.wasm_allocator.rawFree(buf, alignment, ret_addr);
    heap_bytes -= @intCast(buf.len);
}

pub const counting_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = countingAlloc,
        .resize = countingResize,
        .remap = countingRemap,
        .free = countingFree,
    },
};

const TraceEntry = extern struct {
    func_id: i32,
    instructions: i64,
    heap_bytes: i64,
    stable_pages: i64,
};

const entry_size = @sizeOf(TraceEntry);
const page_size: usize = 2 * 1024 * 1024;
const entries_per_page = page_size / entry_size;

var entries: std.ArrayListUnmanaged(TraceEntry) = .{};
var name_map: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .{};
var tracing_enabled: bool = false;
var entry_mode: bool = false;

fn heapMetric() i64 {
    if (has_counting_allocator) return heap_bytes;
    return @intCast(@wasmMemorySize(0));
}

fn appendEntry(func_id: i32) void {
    if (!tracing_enabled) return;
    entries.append(alloc, .{
        .func_id = func_id,
        .instructions = @intCast(cdk.instructionCounter()),
        .heap_bytes = heapMetric(),
        .stable_pages = @intCast(cdk.ic0.stable64_size()),
    }) catch return;
}

fn registerName(id: i32, name: []const u8) void {
    name_map.put(alloc, id, name) catch return;
}

fn comptimeId(comptime name: []const u8) i32 {
    const hash = std.hash.Fnv1a_32.hash(name);
    const id: i32 = @bitCast(hash | 1);
    return if (id < 0) -id else id;
}

// Wrap an fn() void for automatic entry/exit tracing.
// When profiling is disabled at comptime, returns the original function.
pub fn traced(comptime func: fn () void, comptime name: []const u8) fn () void {
    if (!enabled) return func;
    const id = comptime comptimeId(name);
    return struct {
        var registered: bool = false;
        fn f() void {
            if (!registered) {
                registerName(id, name);
                registered = true;
            }
            if (entry_mode) {
                entries.clearRetainingCapacity();
            }
            appendEntry(id);
            func();
            appendEntry(-id);
        }
    }.f;
}

// Manual instrumentation for sub-function granularity.
pub fn enter(comptime name: []const u8) void {
    if (!enabled) return;
    const id = comptime comptimeId(name);
    if (name_map.get(id) == null) {
        registerName(id, name);
    }
    appendEntry(id);
}

pub fn exit(comptime name: []const u8) void {
    if (!enabled) return;
    const id = comptime comptimeId(name);
    appendEntry(-id);
}

pub fn getCyclesHandler() void {
    const count: i64 = @intCast(cdk.instructionCounter());
    cdk.replyRaw(std.mem.asBytes(&count));
}

pub fn getProfilingHandler() void {
    const arg = cdk.argData();
    const page_idx: u32 = if (arg.len >= 4)
        std.mem.readInt(u32, arg[0..4], .little)
    else
        0;

    const total = entries.items.len;
    const start = @min(@as(usize, page_idx) * entries_per_page, total);
    const end = @min(start + entries_per_page, total);
    const slice = entries.items[start..end];

    const has_next: i32 = if (end < total) @intCast(page_idx + 1) else -1;

    const data_bytes = std.mem.sliceAsBytes(slice);
    if (data_bytes.len != 0) {
        cdk.ic0.msg_reply_data_append(data_bytes.ptr, @intCast(data_bytes.len));
    }
    cdk.ic0.msg_reply_data_append(
        @ptrCast(std.mem.asBytes(&has_next)),
        @sizeOf(i32),
    );
    cdk.ic0.msg_reply();
}

pub fn getProfilingNamesHandler() void {
    // Reply format: repeated [i32 id][u32 name_len][name bytes...]
    const map_keys = name_map.keys();
    const map_vals = name_map.values();
    for (map_keys, map_vals) |id, name| {
        cdk.ic0.msg_reply_data_append(
            @ptrCast(std.mem.asBytes(&id)),
            @sizeOf(i32),
        );
        const len: u32 = @intCast(name.len);
        cdk.ic0.msg_reply_data_append(
            @ptrCast(std.mem.asBytes(&len)),
            @sizeOf(u32),
        );
        cdk.ic0.msg_reply_data_append(name.ptr, @intCast(name.len));
    }
    cdk.ic0.msg_reply();
}

pub fn toggleTracingHandler() void {
    tracing_enabled = !tracing_enabled;
    cdk.replyRaw("");
}

pub fn toggleEntryHandler() void {
    entry_mode = !entry_mode;
    cdk.replyRaw("");
}
