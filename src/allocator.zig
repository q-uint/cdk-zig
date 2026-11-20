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

/// How many bytes of scratch a message keeps for the next one. The arena
/// folds its buffers into one at the end of a message, so the next message's
/// argument, work and reply share one contiguous buffer instead of landing in
/// separate heap regions. A message needing more spills into fresh buffers,
/// which the next reset folds back in, up to this limit.
pub const scratch_retain: usize = if (@hasDecl(options, "scratch_retain"))
    options.scratch_retain
else
    64 * 1024;

// Memory for one message: arguments, replies, call payloads. Freed when the
// message ends, so nothing allocated here outlives it. An update's heap
// persists, so without this every encoded reply would leak.
var arena: std.heap.ArenaAllocator = .init(default);

pub const scratch = arena.allocator();

/// Called by the CDK once a message has replied and sent its calls.
pub fn endMessage() void {
    _ = arena.reset(.{ .retain_with_limit = scratch_retain });
}
