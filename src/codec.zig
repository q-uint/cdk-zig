//! Wire format for entry point arguments, replies, and call arguments.
//!
//! Any format works, Candid, CBOR, protobuf, as long as it provides:
//!
//!     fn encode(a: std.mem.Allocator, comptime T: type, value: T) []const u8
//!     fn decode(a: std.mem.Allocator, comptime T: type, bytes: []const u8) T
//!
//! `a` is freed when the message ends, so neither needs to free anything.

const std = @import("std");
const root = @import("root");

/// Declare `cdk_codec` in your root source file to change it:
///
///     pub const cdk_codec = cdk.CandidCodec;
pub const default = if (@hasDecl(root, "cdk_codec")) root.cdk_codec else Raw;

/// Bytes as they are, and integers as little-endian bytes of their own size.
pub const Raw = struct {
    pub fn encode(a: std.mem.Allocator, comptime T: type, value: T) []const u8 {
        if (comptime isBytes(T)) return value;
        comptime checkInt(T);
        const out = a.alloc(u8, @sizeOf(T)) catch @panic("raw: out of memory");
        std.mem.writeInt(T, out[0..@sizeOf(T)], value, .little);
        return out;
    }

    pub fn decode(_: std.mem.Allocator, comptime T: type, bytes: []const u8) T {
        if (comptime T == []const u8) return bytes;
        comptime checkInt(T);
        if (bytes.len != @sizeOf(T))
            @panic(std.fmt.comptimePrint("raw: expected {d} bytes for {s}", .{ @sizeOf(T), @typeName(T) }));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    // Slices and string literals, anything that coerces to []const u8.
    fn isBytes(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .pointer) return false;
        const p = info.pointer;
        return switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        };
    }

    fn checkInt(comptime T: type) void {
        const info = @typeInfo(T);
        if (info != .int or info.int.bits % 8 != 0)
            @compileError("Raw encodes []const u8 and whole-byte integers, not " ++ @typeName(T));
    }
};
