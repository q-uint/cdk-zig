const std = @import("std");
const memory = @import("memory.zig");
const native_endian = @import("builtin").cpu.arch.endian();

pub const Error = memory.StableMemoryError || error{LayoutMismatch};

/// A magic value for a stable structure, hashed from its name, `version`,
/// the layout of `types` and `params`. Changing a field or a parameter
/// changes the value, so data written at an older layout is refused instead
/// of misread. A change the types do not show, like where entries are
/// placed, bumps `version`.
pub fn fingerprint(
    comptime name: []const u8,
    comptime version: u32,
    comptime types: []const type,
    comptime params: []const u8,
) u64 {
    @setEvalBranchQuota(100_000);
    comptime var desc: []const u8 = std.fmt.comptimePrint("{s}/{d}/{s}", .{ name, version, params });
    inline for (types) |T| desc = desc ++ "/" ++ comptime describe(T);
    const h = comptime std.hash.Wyhash.hash(0, desc);
    return if (h == 0) 1 else h;
}

fn describe(comptime T: type) []const u8 {
    var s: []const u8 = std.fmt.comptimePrint("{d}{{", .{@sizeOf(T)});
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, F| {
        s = s ++ std.fmt.comptimePrint("{s}:{s}@{d},", .{ name, @typeName(F), @offsetOf(T, name) });
    }
    return s ++ "}";
}

/// Read a `T`, an integer or extern struct, stored little-endian at `offset`.
pub fn load(comptime Memory: type, comptime T: type, offset: u64) T {
    var value: T = undefined;
    Memory.read(offset, std.mem.asBytes(&value));
    if (native_endian == .big) std.mem.byteSwap(T, &value);
    return value;
}

/// Write `value` little-endian at `offset`.
pub fn store(comptime Memory: type, comptime T: type, offset: u64, value: T) void {
    var v = value;
    if (native_endian == .big) std.mem.byteSwap(T, &v);
    Memory.write(offset, std.mem.asBytes(&v));
}

/// Check the magic at `base`. Returns true if `magic` is there, or false if
/// the memory is fresh, after growing it to hold `header_size` bytes.
/// Anything else is another structure, or this one at another layout.
pub fn open(comptime Memory: type, base: u64, magic: u64, header_size: u64) Error!bool {
    if (Memory.size() * memory.wasm_page_size >= base + 8) {
        const found = load(Memory, u64, base);
        if (found == magic) return true;
        if (found != 0) return error.LayoutMismatch;
    }
    const required = std.math.divCeil(u64, base + header_size, memory.wasm_page_size) catch unreachable;
    const current = Memory.size();
    if (required > current) _ = try Memory.grow(required - current);
    return false;
}

test "fingerprint follows the layout" {
    const A = extern struct { x: u64 };
    const B = extern struct { x: u32 };
    const C = extern struct { y: u64 };
    const a = fingerprint("s", 1, &.{A}, "");
    try std.testing.expectEqual(a, fingerprint("s", 1, &.{A}, ""));
    try std.testing.expect(a != fingerprint("s", 1, &.{B}, ""));
    try std.testing.expect(a != fingerprint("s", 1, &.{C}, ""));
    try std.testing.expect(a != fingerprint("s", 2, &.{A}, ""));
    try std.testing.expect(a != fingerprint("s", 1, &.{A}, "n=1"));
}
