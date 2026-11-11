//! Wire format for entry point arguments, replies, and call arguments.
//!
//! Any format works, Candid, CBOR, protobuf, as long as it provides:
//!
//!     fn encode(comptime T: type, value: T) []const u8
//!     fn decode(comptime T: type, bytes: []const u8) T

const root = @import("root");

/// Declare `cdk_codec` in your root source file to change it:
///
///     pub const cdk_codec = cdk.CandidCodec;
pub const default = if (@hasDecl(root, "cdk_codec")) root.cdk_codec else Raw;

pub const Raw = struct {
    pub fn encode(comptime _: type, value: []const u8) []const u8 {
        return value;
    }

    pub fn decode(comptime _: type, bytes: []const u8) []const u8 {
        return bytes;
    }
};
