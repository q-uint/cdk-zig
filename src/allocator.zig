// The allocator used by all CDK internals (cdk.zig, call.zig, principal.zig, etc.).
//
// Override it by declaring `cdk_allocator` in your root source file:
//
//     pub const cdk_allocator = std.heap.page_allocator;
//
// If not declared, defaults to:
//   - profiling.counting_allocator when cdk_profiling is enabled (wasm32)
//   - wasm_allocator on wasm32
//   - page_allocator otherwise
const std = @import("std");
const root = @import("root");
const profiling = @import("profiling.zig");

pub const default = if (@hasDecl(root, "cdk_allocator"))
    root.cdk_allocator
else if (@import("builtin").target.cpu.arch == .wasm32)
    if (profiling.enabled) profiling.counting_allocator else std.heap.wasm_allocator
else
    std.heap.page_allocator;
