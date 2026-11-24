//! Wire format for entry point arguments, replies, and call arguments.
//!
//! Any format works, Candid, CBOR, protobuf, as long as it provides:
//!
//!     fn encode(a: std.mem.Allocator, comptime T: type, value: T) ![]const u8
//!     fn decode(a: std.mem.Allocator, comptime T: type, bytes: []const u8) !T
//!
//! `a` is freed when the message ends, so neither needs to free anything. An
//! argument that fails to decode rejects the message, naming the error.
//!
//! A handler returning `void` replies with `pub const empty: []const u8` if
//! declared, no bytes otherwise.

const std = @import("std");
const root = @import("root");

/// Declare `cdk_codec` in your root source file to change it:
///
///     pub const cdk_codec = cdk.CandidCodec;
pub const default = if (@hasDecl(root, "cdk_codec")) root.cdk_codec else Raw;

/// What `Codec` replies with when there is no value to reply with.
pub fn empty(comptime Codec: type) []const u8 {
    return if (@hasDecl(Codec, "empty")) Codec.empty else "";
}

/// Bytes as they are, and integers as little-endian bytes of their own size.
pub const Raw = struct {
    pub fn encode(a: std.mem.Allocator, comptime T: type, value: T) error{OutOfMemory}![]const u8 {
        if (comptime isBytes(T)) return value;
        comptime checkInt(T);
        const out = try a.alloc(u8, @sizeOf(T));
        std.mem.writeInt(T, out[0..@sizeOf(T)], value, .little);
        return out;
    }

    pub fn decode(_: std.mem.Allocator, comptime T: type, bytes: []const u8) error{WrongLength}!T {
        if (comptime T == []const u8) return bytes;
        comptime checkInt(T);
        if (bytes.len != @sizeOf(T)) return error.WrongLength;
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
