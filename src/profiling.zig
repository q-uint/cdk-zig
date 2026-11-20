// Compile-time opt-in profiling module for flamegraph / cycle cost analysis.
//
// Enable it from build.zig, which builds `{name}_profiling.wasm` next to the
// plain canister:
//
//     _ = cdk.addCanister(b, dep, "app", .{ .profiling = true });
//
// or by declaring in your root source file:
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
const build_options = @import("cdk_build_options");

pub const enabled = build_options.profiling or
    (@hasDecl(root, "cdk_profiling") and root.cdk_profiling);

/// With profiling on, every query is exported a second time as an update
/// named `__profile_<name>`. Queries roll back their state, the trace
/// included, so only the update leaves a trace to fetch.
pub const query_prefix = "__profile_";

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

// The trace's own memory bypasses the counting allocator, so heap_bytes
// measures the canister rather than the profiler.
const trace_allocator = std.heap.wasm_allocator;

var entries: std.ArrayListUnmanaged(TraceEntry) = .empty;
var name_map: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .{};
var tracing_enabled: bool = false;
var entry_mode: bool = false;

// Entries the buffer holds, and names the table takes, before either has to
// grow inside a frame.
const reserved_entries = 4096;
const reserved_names = 64;
const os_page_size = 4096;

// Runs before an entry point's first counter read. Growing the buffer, and
// the first write to each of its pages in a message, cost instructions that
// would otherwise land in whichever frame is open.
fn reserve() void {
    if (!tracing_enabled) return;
    name_map.ensureUnusedCapacity(trace_allocator, reserved_names) catch {};
    entries.ensureUnusedCapacity(trace_allocator, reserved_entries) catch return;
    const spare = std.mem.sliceAsBytes(entries.unusedCapacitySlice());
    var offset: usize = 0;
    while (offset < spare.len) : (offset += os_page_size) {
        const byte: *volatile u8 = &spare[offset];
        byte.* = 0;
    }
}

fn heapMetric() i64 {
    if (has_counting_allocator) return heap_bytes;
    return @intCast(@wasmMemorySize(0));
}

fn appendEntry(func_id: i32) void {
    if (!tracing_enabled) return;
    entries.append(trace_allocator, .{
        .func_id = func_id,
        .instructions = @intCast(cdk.instructionCounter()),
        .heap_bytes = heapMetric(),
        .stable_pages = @intCast(cdk.ic0.stable64_size()),
    }) catch return;
}

fn registerName(id: i32, name: []const u8) void {
    name_map.put(trace_allocator, id, name) catch return;
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
            reserve();
            appendEntry(id);
            func();
            appendEntry(-id);
        }
    }.f;
}

/// A traced section, from `section` to its `end`. Ending it with `defer`
/// closes it on every path out, an early `try` return included:
///
///     const s = cdk.profiling.section("tree.append");
///     defer s.end();
pub const Section = if (enabled) struct {
    id: i32,

    pub fn end(self: Section) void {
        appendEntry(-self.id);
    }
} else struct {
    pub fn end(_: Section) void {}
};

pub fn section(comptime name: []const u8) Section {
    if (comptime !enabled) {
        return .{};
    } else {
        enter(name);
        return .{ .id = comptime comptimeId(name) };
    }
}

// Manual instrumentation for sub-function granularity. Prefer `section`,
// since an `exit` skipped by an early return leaves its frame open.
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

// The endpoints below are exported with the Raw codec, see export.zig.

pub fn getInstructions() i64 {
    return @intCast(cdk.instructionCounter());
}

// Reply format: the page's entries, then the next page as an i32, -1 if none.
pub fn getProfiling(scratch: std.mem.Allocator, page: u32) ![]const u8 {
    const total = entries.items.len;
    const start = @min(@as(usize, page) * entries_per_page, total);
    const end = @min(start + entries_per_page, total);
    const next: i32 = if (end < total) @intCast(page + 1) else -1;

    return std.mem.concat(scratch, u8, &.{
        std.mem.sliceAsBytes(entries.items[start..end]),
        std.mem.asBytes(&next),
    });
}

// Reply format: repeated [i32 id][u32 name_len][name bytes...]
pub fn getProfilingNames(scratch: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name_map.keys(), name_map.values()) |id, name| {
        const len: u32 = @intCast(name.len);
        try out.appendSlice(scratch, std.mem.asBytes(&id));
        try out.appendSlice(scratch, std.mem.asBytes(&len));
        try out.appendSlice(scratch, name);
    }
    return out.items;
}

const RawReply = cdk.TransitionWith(cdk.RawCodec, void);

// Argument: two bytes, tracing then entry_mode, each 0 or 1. Turning tracing
// on starts a fresh trace, so a test sees only what it ran after.
pub fn setProfiling(arg: []const u8) RawReply {
    if (arg.len != 2 or arg[0] > 1 or arg[1] > 1)
        return .reject(
            "__set_profiling takes two bytes, tracing and entry_mode, each 0 or 1",
        );
    tracing_enabled = arg[0] == 1;
    entry_mode = arg[1] == 1;
    if (tracing_enabled) entries.clearRetainingCapacity();
    return .replyRaw("");
}

// The toggles match ic-wasm's endpoints. Prefer __set_profiling, whose
// effect does not depend on state the caller cannot see.
pub fn toggleTracing() void {
    tracing_enabled = !tracing_enabled;
    cdk.replyRaw("");
}

pub fn toggleEntry() void {
    entry_mode = !entry_mode;
    cdk.replyRaw("");
}
