const types = @import("types.zig");
const encoding = @import("encoding.zig");
const decoding = @import("decoding.zig");

pub const Principal = types.Principal;
pub const Blob = types.Blob;
pub const Reserved = types.Reserved;
pub const Empty = types.Empty;
pub const RecursiveOpt = types.RecursiveOpt;
pub const Func = types.Func;
pub const FuncType = types.FuncType;
pub const FuncAnnotation = types.FuncAnnotation;
pub const QueryFunc = types.QueryFunc;
pub const OnewayFunc = types.OnewayFunc;
pub const CompositeQueryFunc = types.CompositeQueryFunc;
pub const Service = types.Service;
pub const fieldHash = types.fieldHash;

pub const encode = encoding.encode;
pub const empty_args = encoding.empty_args;

pub const decode = decoding.decode;
pub const decodeAdvanced = decoding.decodeAdvanced;
pub const decodeMany = decoding.decodeMany;
pub const decodeManyAdvanced = decoding.decodeManyAdvanced;
pub const DecodeOptions = decoding.DecodeOptions;
pub const DecodeError = decoding.DecodeError;

test {
    _ = types;
    _ = encoding;
    _ = decoding;
    _ = @import("conformance/prim.zig");
    _ = @import("conformance/construct.zig");
    _ = @import("conformance/reference.zig");
    _ = @import("conformance/overshoot.zig");
    _ = @import("conformance/spacebomb.zig");
    _ = @import("conformance/subtypes.zig");
}
