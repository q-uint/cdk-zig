const std = @import("std");

pub const Principal = struct {
    bytes: []const u8,

    pub fn from(b: []const u8) Principal {
        return .{ .bytes = b };
    }
};

pub const Blob = struct {
    data: []const u8,

    pub fn from(b: []const u8) Blob {
        return .{ .data = b };
    }
};

pub const Reserved = struct {};

/// The candid `empty` type. No valid value can be decoded for this type.
pub const Empty = enum { empty };

/// Marker type for the candid recursive optional: `type Opt = opt Opt`.
///
/// Zig has no recursive type aliases, so the infinitely-nested `opt opt opt ...`
/// cannot be expressed as `??...void`. Using `??void` would give the decoder only
/// two levels of nesting, causing it to silently coerce incompatible wire types
/// to `null` instead of rejecting them.
///
/// When the decoder sees `?RecursiveOpt` as the target type and the wire type is
/// not `opt`, it returns `TypeMismatch` rather than attempting the `T <: opt T`
/// coercion that would succeed with finite nesting. This matches the candid spec
/// behavior for `Opt = opt Opt`.
///
/// Usage:
///   const val = try decode(?RecursiveOpt, allocator, bytes);
///   // val is null or RecursiveOpt.some (use .unwrap() for inner ?RecursiveOpt)
pub const RecursiveOpt = struct {
    _inner: ?*const RecursiveOpt = null,

    pub fn unwrap(self: RecursiveOpt) ?RecursiveOpt {
        if (self._inner) |ptr| return ptr.*;
        return null;
    }

    pub fn deinit(self: RecursiveOpt, alloc: std.mem.Allocator) void {
        if (self._inner) |ptr| {
            ptr.deinit(alloc);
            alloc.destroy(ptr);
        }
    }
};

pub const FuncAnnotation = enum(u8) {
    none = 0,
    query = 1,
    oneway = 2,
    composite_query = 3,
};

pub fn FuncType(comptime mode: FuncAnnotation) type {
    return struct {
        pub const annotation = mode;

        service: Principal,
        method: []const u8,

        const Self = @This();
        pub fn from(service: Principal, method: []const u8) Self {
            return .{ .service = service, .method = method };
        }
    };
}

pub const Func = FuncType(.none);
pub const QueryFunc = FuncType(.query);
pub const OnewayFunc = FuncType(.oneway);
pub const CompositeQueryFunc = FuncType(.composite_query);

pub const Service = struct {
    principal: Principal,

    pub fn from(p: Principal) Service {
        return .{ .principal = p };
    }
};

pub const type_null: i32 = -1;
pub const type_bool: i32 = -2;
pub const type_nat: i32 = -3;
pub const type_int: i32 = -4;
pub const type_nat8: i32 = -5;
pub const type_nat16: i32 = -6;
pub const type_nat32: i32 = -7;
pub const type_nat64: i32 = -8;
pub const type_int8: i32 = -9;
pub const type_int16: i32 = -10;
pub const type_int32: i32 = -11;
pub const type_int64: i32 = -12;
pub const type_float32: i32 = -13;
pub const type_float64: i32 = -14;
pub const type_text: i32 = -15;
pub const type_reserved: i32 = -16;
pub const type_empty: i32 = -17;
pub const type_opt: i32 = -18;
pub const type_vec: i32 = -19;
pub const type_record: i32 = -20;
pub const type_variant: i32 = -21;
pub const type_func: i32 = -22;
pub const type_service: i32 = -23;
pub const type_principal: i32 = -24;

pub fn fieldHashRuntime(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| {
        h = h *% 223 +% c;
    }
    return h;
}

pub fn fieldHash(comptime name: []const u8) u32 {
    // Candid uses numeric field hashes directly: field "42" has hash 42.
    // This allows Zig types to use @"0", @"1", etc. as field names for
    // numbered candid fields.
    if (parseNumericHash(name)) |n| return n;
    return fieldHashRuntime(name);
}

fn parseNumericHash(comptime name: []const u8) ?u32 {
    if (name.len == 0) return null;
    var n: u32 = 0;
    for (name) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u32 = c - '0';
        n = std.math.mul(u32, n, 10) catch return null;
        n = std.math.add(u32, n, digit) catch return null;
    }
    return n;
}

pub fn isPrimitive(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => true,
        else => false,
    };
}

pub fn isFuncType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasDecl(T, "annotation") and @TypeOf(T.annotation) == FuncAnnotation;
}

pub fn isText(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

pub const SortedField = struct {
    hash: u32,
    name: [:0]const u8,
    field_type: type,
};

pub fn sortedStructFields(comptime T: type) [@typeInfo(T).@"struct".fields.len]SortedField {
    comptime {
        const s = @typeInfo(T).@"struct";
        const fields = s.fields;
        var result: [fields.len]SortedField = undefined;
        for (fields, 0..) |f, i| {
            const hash: u32 = if (s.is_tuple) @intCast(i) else fieldHash(f.name);
            result[i] = .{ .hash = hash, .name = f.name, .field_type = f.type };
        }
        for (0..result.len) |i| {
            for (i + 1..result.len) |j| {
                if (result[j].hash < result[i].hash) {
                    const tmp = result[i];
                    result[i] = result[j];
                    result[j] = tmp;
                }
            }
        }
        return result;
    }
}

pub fn sortedUnionFields(comptime T: type) [@typeInfo(T).@"union".fields.len]SortedField {
    comptime {
        const fields = @typeInfo(T).@"union".fields;
        var result: [fields.len]SortedField = undefined;
        for (fields, 0..) |f, i| {
            result[i] = .{ .hash = fieldHash(f.name), .name = f.name, .field_type = f.type };
        }
        for (0..result.len) |i| {
            for (i + 1..result.len) |j| {
                if (result[j].hash < result[i].hash) {
                    const tmp = result[i];
                    result[i] = result[j];
                    result[j] = tmp;
                }
            }
        }
        return result;
    }
}

pub fn ulebComptime(comptime value: u128) []const u8 {
    comptime {
        var v = value;
        var bytes: []const u8 = &.{};
        while (true) {
            const b: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) return bytes ++ &[_]u8{b};
            bytes = bytes ++ &[_]u8{b | 0x80};
        }
    }
}

pub fn slebComptime(comptime value: i32) []const u8 {
    comptime {
        var v: i32 = value;
        var bytes: []const u8 = &.{};
        while (true) {
            const b: u8 = @truncate(@as(u32, @bitCast(v)) & 0x7f);
            v >>= 7;
            if ((v == 0 and (b & 0x40) == 0) or (v == -1 and (b & 0x40) != 0))
                return bytes ++ &[_]u8{b};
            bytes = bytes ++ &[_]u8{b | 0x80};
        }
    }
}

const testing = std.testing;

test "field hash known values" {
    try testing.expectEqual(@as(u32, 0), fieldHash(""));
    try testing.expectEqual(fieldHash("name"), fieldHash("name"));
    try testing.expect(fieldHash("age") < fieldHash("name"));
}

test "parseNumericHash overflow falls through to string hash" {
    // "99999999999" overflows u32 (max 4294967295), so it must not be
    // treated as a numeric field. It should fall through to the string
    // hash instead.
    const overflow_name = "99999999999";
    const hash = fieldHash(overflow_name);

    // If parseNumericHash correctly returns null on overflow, fieldHash
    // computes the string hash. The string hash for this input is not
    // the wrapped numeric value.
    var expected: u32 = 0;
    for (overflow_name) |c| {
        expected = expected *% 223 +% c;
    }
    try testing.expectEqual(expected, hash);
}
