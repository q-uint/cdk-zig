const std = @import("std");
const leb = std.leb;
const Allocator = std.mem.Allocator;
const t = @import("types.zig");

const type_null = t.type_null;
const type_bool = t.type_bool;
const type_nat = t.type_nat;
const type_int = t.type_int;
const type_nat8 = t.type_nat8;
const type_nat16 = t.type_nat16;
const type_nat32 = t.type_nat32;
const type_nat64 = t.type_nat64;
const type_int8 = t.type_int8;
const type_int16 = t.type_int16;
const type_int32 = t.type_int32;
const type_int64 = t.type_int64;
const type_float32 = t.type_float32;
const type_float64 = t.type_float64;
const type_text = t.type_text;
const type_reserved = t.type_reserved;
const type_empty = t.type_empty;
const type_opt = t.type_opt;
const type_vec = t.type_vec;
const type_record = t.type_record;
const type_variant = t.type_variant;
const type_func = t.type_func;
const type_service = t.type_service;
const type_principal = t.type_principal;

fn hasDefault(comptime T: type) bool {
    if (T == void) return true;
    if (T == t.Reserved) return true;
    if (@typeInfo(T) == .optional) return true;
    return false;
}

fn defaultValue(comptime T: type) T {
    if (T == void) return {};
    if (T == t.Reserved) return .{};
    if (@typeInfo(T) == .optional) return null;
    unreachable;
}

pub fn Decoded(comptime T: type) type {
    return struct {
        value: T,
        alloc: Allocator,

        pub fn deinit(self: *@This()) void {
            freeDecoded(T, self.alloc, self.value);
            self.* = undefined;
        }
    };
}

pub fn decodeOwned(comptime T: type, alloc: Allocator, data: []const u8) DecodeError!Decoded(T) {
    return decodeOwnedAdvanced(T, alloc, data, .{});
}

pub fn decodeOwnedAdvanced(comptime T: type, alloc: Allocator, data: []const u8, options: DecodeOptions) DecodeError!Decoded(T) {
    const val = try decodeAdvanced(T, alloc, data, options);
    return .{ .value = val, .alloc = alloc };
}

pub fn freeDecoded(comptime T: type, alloc: Allocator, val: T) void {
    if (T == t.Principal) {
        alloc.free(val.bytes);
        return;
    }
    if (comptime t.isFuncType(T)) {
        alloc.free(val.service.bytes);
        alloc.free(val.method);
        return;
    }
    if (T == t.Service) {
        alloc.free(val.principal.bytes);
        return;
    }
    if (T == t.Blob) {
        alloc.free(val.data);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice) {
                for (val) |item| {
                    freeDecoded(p.child, alloc, item);
                }
                alloc.free(val);
            } else if (p.size == .one) {
                freeDecoded(p.child, alloc, val.*);
                alloc.destroy(val);
            }
        },
        .optional => {
            if (val) |v| freeDecoded(@typeInfo(T).optional.child, alloc, v);
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                freeDecoded(field.type, alloc, @field(val, field.name));
            }
        },
        .@"union" => |u| {
            if (u.tag_type) |_| {
                inline for (u.fields) |field| {
                    if (val == @field(T, field.name)) {
                        freeDecoded(field.type, alloc, @field(val, field.name));
                        return;
                    }
                }
            }
        },
        else => {},
    }
}

fn mapLebError(err: anytype) DecodeError {
    return switch (@as(anyerror, err)) {
        error.EndOfStream => error.EndOfStream,
        else => error.Overflow,
    };
}

pub const DecodeError = error{
    InvalidMagic,
    TypeMismatch,
    MissingField,
    InvalidVariantIndex,
    UnknownVariant,
    UnsupportedType,
    UnsupportedPrincipalRef,
    EndOfStream,
    Overflow,
    OutOfMemory,
    TrailingBytes,
    InvalidUtf8,
};

pub const DecodeOptions = struct {
    /// Maximum number of elements in a vec whose wire element type is
    /// zero-sized (null, reserved, empty record). Without this limit a
    /// malicious message can claim billions of zero-sized elements,
    /// causing the decoder to loop or allocate excessively.
    /// Set to 0 for no limit (not recommended in untrusted contexts).
    max_zero_sized_vec_len: u32 = 1_000_000,
};

pub fn decode(comptime T: type, alloc: Allocator, data: []const u8) DecodeError!T {
    return decodeAdvanced(T, alloc, data, .{});
}

pub fn decodeAdvanced(comptime T: type, alloc: Allocator, data: []const u8, options: DecodeOptions) DecodeError!T {
    const result = try decodeManyAdvanced(struct { T }, alloc, data, options);
    return result[0];
}

pub fn decodeMany(comptime Types: type, alloc: Allocator, data: []const u8) DecodeError!Types {
    return decodeManyAdvanced(Types, alloc, data, .{});
}

pub fn decodeManyAdvanced(comptime Types: type, alloc: Allocator, data: []const u8, options: DecodeOptions) DecodeError!Types {
    const info = @typeInfo(Types);
    if (info != .@"struct" or (!info.@"struct".is_tuple and info.@"struct".fields.len > 0))
        @compileError("Types must be a tuple, e.g. struct { u32, []const u8 }");

    const fields = info.@"struct".fields;

    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    var magic_buf: [4]u8 = undefined;
    reader.readNoEof(&magic_buf) catch return error.InvalidMagic;
    if (!std.mem.eql(u8, &magic_buf, "DIDL")) return error.InvalidMagic;

    const type_count = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    const remaining = data.len - fbs.pos;
    if (type_count > remaining) return error.EndOfStream;
    const type_table = alloc.alloc(TypeEntry, type_count) catch return error.OutOfMemory;
    @memset(type_table, TypeEntry{});
    defer {
        for (type_table) |entry| {
            if (entry.fields.len > 0) alloc.free(entry.fields);
            if (entry.func_args.len > 0) alloc.free(entry.func_args);
            if (entry.func_results.len > 0) alloc.free(entry.func_results);
        }
        alloc.free(type_table);
    }
    for (type_table) |*entry| {
        entry.* = parseTypeEntry(reader, alloc, data.len) catch |e| return switch (@as(anyerror, e)) {
            error.UnsupportedType => error.UnsupportedType,
            else => mapLebError(e),
        };
    }

    // Validate all type refs in the table
    for (type_table) |entry| {
        switch (entry.opcode) {
            type_opt, type_vec => {
                if (!isValidRef(entry.inner, type_count)) return error.UnsupportedType;
            },
            type_record, type_variant => {
                var prev_hash: ?u32 = null;
                for (entry.fields) |f| {
                    if (!isValidRef(f.type_ref, type_count)) return error.UnsupportedType;
                    if (prev_hash) |ph| {
                        if (f.hash <= ph) return error.TypeMismatch;
                    }
                    prev_hash = f.hash;
                }
            },
            type_func => {
                for (entry.func_args) |a| {
                    if (!isValidRef(a, type_count)) return error.UnsupportedType;
                }
                for (entry.func_results) |r| {
                    if (!isValidRef(r, type_count)) return error.UnsupportedType;
                }
            },
            type_service => {
                for (entry.fields) |f| {
                    if (!isValidRef(f.type_ref, type_count)) return error.UnsupportedType;
                    // Service method type refs must point to func types
                    if (f.type_ref >= 0) {
                        if (type_table[@intCast(f.type_ref)].opcode != type_func)
                            return error.UnsupportedType;
                    } else {
                        // Primitive type refs are never func types
                        return error.UnsupportedType;
                    }
                }
            },
            else => {},
        }
    }

    // Pre-compute unguarded cycle flags: a single pass over the type
    // table replaces the per-field allocations that decodeRecord/decodeVariant
    // previously performed.
    const cycle_flags = if (type_count > 0) blk: {
        const flags = alloc.alloc(bool, type_count) catch return error.OutOfMemory;
        const visited = alloc.alloc(bool, type_count) catch return error.OutOfMemory;
        defer alloc.free(visited);
        for (0..type_count) |i| {
            @memset(visited, false);
            flags[i] = hasUnguardedCycleInner(type_table, @intCast(i), visited);
        }
        break :blk flags;
    } else blk: {
        var empty: [0]bool = .{};
        break :blk @as([]bool, &empty);
    };
    defer if (type_count > 0) alloc.free(cycle_flags);

    const arg_count = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);

    var ref_buf: [0]i32 = .{};
    const all_refs = if (arg_count > 0)
        alloc.alloc(i32, arg_count) catch return error.OutOfMemory
    else
        @as([]i32, &ref_buf);
    defer if (arg_count > 0) alloc.free(all_refs);
    for (all_refs) |*r| {
        r.* = leb.readIleb128(i32, reader) catch |e| return mapLebError(e);
    }

    const readable = @min(arg_count, fields.len);

    var result: Types = undefined;
    inline for (fields, 0..) |field, i| {
        if (i < readable) {
            result[i] = try decodeValue(field.type, reader, type_table, all_refs[i], alloc, data.len, options, cycle_flags);
        } else {
            if (comptime !hasDefault(field.type)) return error.TypeMismatch;
            result[i] = defaultValue(field.type);
        }
    }

    // Skip values of extra args beyond what fields consumes
    if (arg_count > fields.len) {
        for (fields.len..arg_count) |i| {
            try skipValue(reader, type_table, all_refs[i]);
        }
    }

    // Reject trailing bytes after all args are consumed
    if (fbs.pos != data.len) {
        inline for (fields) |field| {
            freeDecoded(field.type, alloc, @field(result, field.name));
        }
        return error.TrailingBytes;
    }

    return result;
}

pub const FieldEntry = struct {
    hash: u32,
    type_ref: i32,
};

pub const TypeEntry = struct {
    opcode: i32 = 0,
    inner: i32 = 0,
    fields: []const FieldEntry = &.{},
    func_args: []const i32 = &.{},
    func_results: []const i32 = &.{},
    annotations: u8 = 0,
};

// Detect if a record/variant type can reach itself through record/variant
// fields only (no opt/vec in the path). Such cycles create infinite
// structures with no base case.
fn hasUnguardedCycleInner(table: []const TypeEntry, ref_u: u32, visited: []bool) bool {
    if (ref_u >= table.len) return false;
    if (visited[ref_u]) return true;
    const entry = table[ref_u];
    switch (entry.opcode) {
        type_record => {
            // All record fields are decoded, so ANY recursive field is unguarded.
            visited[ref_u] = true;
            defer visited[ref_u] = false;
            for (entry.fields) |f| {
                if (f.type_ref < 0) continue;
                if (hasUnguardedCycleInner(table, @intCast(f.type_ref), visited)) return true;
            }
            return false;
        },
        type_variant => {
            // A variant selects one branch. It's a guard only if at least one
            // branch does NOT cycle back. If ALL branches cycle, it's unguarded.
            if (entry.fields.len == 0) return false;
            visited[ref_u] = true;
            defer visited[ref_u] = false;
            for (entry.fields) |f| {
                if (f.type_ref < 0) return false; // primitive field = safe branch
                if (!hasUnguardedCycleInner(table, @intCast(f.type_ref), visited)) return false;
            }
            return true; // all branches cycle
        },
        type_opt, type_vec => return false,
        else => return false,
    }
}

fn isValidRef(ref: i32, table_len: u32) bool {
    if (ref >= 0) return @as(u32, @intCast(ref)) < table_len;
    // Primitive type codes -1 (null) through -17 (empty) and -24 (principal)
    // are valid as bare refs. Compound opcodes -18 through -23 (opt, vec,
    // record, variant, func, service) are only valid inside the type table,
    // not as standalone refs.
    if (ref >= type_empty and ref <= type_null) return true;
    if (ref == type_principal) return true;
    return false;
}

fn parseTypeEntry(reader: anytype, alloc: Allocator, data_len: usize) !TypeEntry {
    const opcode = try leb.readIleb128(i32, reader);
    // Only compound type constructors are valid in the type table:
    // opt(-18), vec(-19), record(-20), variant(-21), func(-22), service(-23),
    // and future types (< -24). Reject primitives (-17..-1), principal (-24),
    // and table refs (>= 0).
    if (opcode >= 0 or opcode > type_opt or opcode == type_principal)
        return error.UnsupportedType;
    switch (opcode) {
        type_opt, type_vec => {
            return .{ .opcode = opcode, .inner = try leb.readIleb128(i32, reader) };
        },
        type_record, type_variant => {
            const n = try leb.readUleb128(u32, reader);
            // Each field needs at least 2 bytes (hash LEB + type_ref LEB)
            if (n > data_len / 2) return error.EndOfStream;
            const fields = try alloc.alloc(FieldEntry, n);
            errdefer alloc.free(fields);
            for (fields) |*f| {
                f.hash = try leb.readUleb128(u32, reader);
                f.type_ref = try leb.readIleb128(i32, reader);
            }
            return .{ .opcode = opcode, .fields = fields };
        },
        -22 => { // func
            const np = try leb.readUleb128(u32, reader);
            if (np > data_len) return error.EndOfStream;
            const func_args = try alloc.alloc(i32, np);
            errdefer if (np > 0) alloc.free(func_args);
            for (func_args) |*a| a.* = try leb.readIleb128(i32, reader);
            const nr = try leb.readUleb128(u32, reader);
            if (nr > data_len) return error.EndOfStream;
            const func_results = try alloc.alloc(i32, nr);
            errdefer if (nr > 0) alloc.free(func_results);
            for (func_results) |*r| r.* = try leb.readIleb128(i32, reader);
            const na = try leb.readUleb128(u32, reader);
            var annotation: u8 = 0;
            for (0..na) |_| {
                const a = try leb.readUleb128(u8, reader);
                if (a > 3) return error.UnsupportedType;
                annotation = a;
            }
            return .{ .opcode = opcode, .func_args = func_args, .func_results = func_results, .annotations = annotation };
        },
        -23 => { // service
            const nm = try leb.readUleb128(u32, reader);
            if (nm > data_len / 2) return error.EndOfStream;
            const methods = try alloc.alloc(FieldEntry, nm);
            errdefer alloc.free(methods);
            var stack_bufs: [2][256]u8 = undefined;
            var cur_stack: u1 = 0;
            var prev_name: []u8 = &.{};
            var prev_heap: ?[]u8 = null;
            defer if (prev_heap) |h| alloc.free(h);
            for (methods) |*m| {
                const name_len = try leb.readUleb128(u32, reader);
                if (name_len > data_len) return error.EndOfStream;
                const is_heap = name_len > stack_bufs[0].len;
                const name = if (is_heap)
                    alloc.alloc(u8, name_len) catch return error.OutOfMemory
                else
                    stack_bufs[cur_stack][0..name_len];
                reader.readNoEof(name) catch return error.EndOfStream;
                if (!std.unicode.utf8ValidateSlice(name))
                    return error.UnsupportedType;
                if (prev_name.len > 0) {
                    if (std.mem.order(u8, name, prev_name) != .gt)
                        return error.UnsupportedType;
                }
                if (prev_heap) |h| alloc.free(h);
                prev_heap = if (is_heap) name else null;
                prev_name = name;
                if (!is_heap) cur_stack ^= 1;
                m.hash = t.fieldHashRuntime(name);
                m.type_ref = try leb.readIleb128(i32, reader);
            }
            return .{ .opcode = opcode, .fields = methods };
        },
        else => {
            if (opcode < type_principal) {
                const count = try leb.readUleb128(u32, reader);
                try reader.skipBytes(count, .{});
            }
            return .{ .opcode = opcode };
        },
    }
}

fn wireOpcode(table: []const TypeEntry, ref: i32) i32 {
    if (ref < 0) return ref;
    if (@as(usize, @intCast(ref)) >= table.len) return 0;
    return table[@intCast(ref)].opcode;
}

pub fn isSubtype(table: []const TypeEntry, t1: i32, t2: i32, alloc: Allocator) DecodeError!bool {
    const visited = alloc.alloc(bool, table.len * table.len) catch return error.OutOfMemory;
    defer alloc.free(visited);
    @memset(visited, false);
    return isSubtypeInner(table, t1, t2, visited);
}

fn canOmit(table: []const TypeEntry, ref: i32) bool {
    const op = wireOpcode(table, ref);
    return op == type_opt or op == type_null or op == type_reserved;
}

fn isSubtypeInner(
    table: []const TypeEntry,
    t1: i32,
    t2: i32,
    visited: []bool,
) bool {
    if (t1 == t2) return true;

    const op1 = wireOpcode(table, t1);
    const op2 = wireOpcode(table, t2);

    // empty <: T
    if (op1 == type_empty) return true;
    // T <: reserved
    if (op2 == type_reserved) return true;
    // T <: opt T' for all T, T'
    if (op2 == type_opt) return true;
    // nat <: int
    if (op1 == type_nat and op2 == type_int) return true;

    // Compound types require valid table entries on both sides
    if (t1 < 0 or t2 < 0) return false;
    const idx1: usize = @intCast(t1);
    const idx2: usize = @intCast(t2);
    if (idx1 >= table.len or idx2 >= table.len) return false;
    if (op1 != op2) return false;

    // Coinductive assumption for recursive types
    const key = idx1 * table.len + idx2;
    if (key < visited.len) {
        if (visited[key]) return true;
        visited[key] = true;
    }

    const e1 = table[idx1];
    const e2 = table[idx2];

    if (op1 == type_vec) {
        return isSubtypeInner(table, e1.inner, e2.inner, visited);
    }

    if (op1 == type_record) {
        // Each expected field must match a wire field or be omittable
        for (e2.fields) |f2| {
            var matched = false;
            for (e1.fields) |f1| {
                if (f1.hash == f2.hash) {
                    if (!isSubtypeInner(table, f1.type_ref, f2.type_ref, visited))
                        return false;
                    matched = true;
                    break;
                }
            }
            if (!matched and !canOmit(table, f2.type_ref)) return false;
        }
        return true;
    }

    if (op1 == type_variant) {
        // Each wire field must have a matching expected field
        for (e1.fields) |f1| {
            var matched = false;
            for (e2.fields) |f2| {
                if (f1.hash == f2.hash) {
                    if (!isSubtypeInner(table, f1.type_ref, f2.type_ref, visited))
                        return false;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }

    if (op1 == type_service) {
        // Each expected method must match a wire method
        for (e2.fields) |f2| {
            var matched = false;
            for (e1.fields) |f1| {
                if (f1.hash == f2.hash) {
                    if (!isSubtypeInner(table, f1.type_ref, f2.type_ref, visited))
                        return false;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }

    if (op1 == type_func) {
        // Annotations must match exactly
        if (e1.annotations != e2.annotations) return false;
        // Contravariant args
        const min_a = @min(e1.func_args.len, e2.func_args.len);
        for (0..min_a) |i| {
            if (!isSubtypeInner(table, e2.func_args[i], e1.func_args[i], visited))
                return false;
        }
        for (e1.func_args[min_a..]) |a| {
            if (!canOmit(table, a)) return false;
        }
        for (e2.func_args[min_a..]) |a| {
            if (!canOmit(table, a)) return false;
        }
        // Covariant results
        const min_r = @min(e1.func_results.len, e2.func_results.len);
        for (0..min_r) |i| {
            if (!isSubtypeInner(table, e1.func_results[i], e2.func_results[i], visited))
                return false;
        }
        for (e2.func_results[min_r..]) |r| {
            if (!canOmit(table, r)) return false;
        }
        return true;
    }

    return false;
}

fn isWireCompatible(comptime T: type, opcode: i32) bool {
    if (T == t.Principal) return opcode == type_principal;
    if (T == t.Blob) return opcode == type_vec;
    if (comptime t.isFuncType(T)) return opcode == type_func;
    if (T == t.Service) return opcode == type_service;
    if (T == t.Reserved) return true;
    if (T == t.RecursiveOpt) return opcode == type_opt;
    if (T == void) return opcode == type_null;
    if (comptime t.isText(T)) return opcode == type_text or opcode == type_vec;
    switch (@typeInfo(T)) {
        .bool => return opcode == type_bool,
        .int => |info| return switch (info.signedness) {
            .unsigned => switch (info.bits) {
                8 => opcode == type_nat8,
                16 => opcode == type_nat16,
                32 => opcode == type_nat32,
                64 => opcode == type_nat64,
                128 => opcode == type_nat,
                else => false,
            },
            .signed => switch (info.bits) {
                8 => opcode == type_int8,
                16 => opcode == type_int16,
                32 => opcode == type_int32,
                64 => opcode == type_int64,
                128 => opcode == type_int or opcode == type_nat,
                else => false,
            },
        },
        .float => |info| return switch (info.bits) {
            32 => opcode == type_float32,
            64 => opcode == type_float64,
            else => false,
        },
        .optional => |o| return opcode == type_opt or
            opcode == type_null or
            opcode == type_reserved or
            isWireCompatible(o.child, opcode),
        .pointer => |p| {
            if (p.size == .slice) return opcode == type_vec;
            if (p.size == .one) return isWireCompatible(p.child, opcode);
            return false;
        },
        .@"struct" => return opcode == type_record,
        .@"union" => return opcode == type_variant,
        else => return false,
    }
}

fn decodeValue(comptime T: type, reader: anytype, table: []const TypeEntry, ref: i32, alloc: Allocator, data_len: usize, options: DecodeOptions, cycle_flags: []const bool) DecodeError!T {
    // empty type can never be decoded
    if (T == t.Empty) return error.TypeMismatch;

    // t.RecursiveOpt: decode as if target were ?t.RecursiveOpt (one more level of opt).
    // The inner value is allocated on the heap to break the type recursion.
    if (T == t.RecursiveOpt) {
        const inner = try decodeValue(?t.RecursiveOpt, reader, table, ref, alloc, data_len, options, cycle_flags);
        if (inner) |val| {
            const ptr = alloc.create(t.RecursiveOpt) catch return error.OutOfMemory;
            ptr.* = val;
            return t.RecursiveOpt{ ._inner = ptr };
        }
        return t.RecursiveOpt{ ._inner = null };
    }

    const opcode = wireOpcode(table, ref);

    // opt coercions: null/reserved -> null, T <: opt T
    if (comptime @typeInfo(T) == .optional) {
        if (opcode == type_null) return null;
        if (opcode == type_reserved) return null;
        if (opcode != type_opt) {
            const Child = @typeInfo(T).optional.child;
            // t.RecursiveOpt: the candid type `Opt = opt Opt` has infinite nesting.
            // A non-opt wire type can never be coerced into it (the T <: opt T
            // rule would recurse forever), so reject immediately.
            if (Child == t.RecursiveOpt) return error.TypeMismatch;
            // T <: opt T: if wire is compatible with child, decode and wrap
            if (isWireCompatible(Child, opcode)) {
                return try decodeValue(Child, reader, table, ref, alloc, data_len, options, cycle_flags);
            }
            // Incompatible or future type: skip value, produce null
            try skipValue(reader, table, ref);
            return null;
        }
    }

    // Single-item pointer: allocate and decode pointee.
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one) {
        const Child = @typeInfo(T).pointer.child;
        const ptr = alloc.create(Child) catch return error.OutOfMemory;
        ptr.* = try decodeValue(Child, reader, table, ref, alloc, data_len, options, cycle_flags);
        return ptr;
    }

    // nat <: int coercion
    if (T == i128 and opcode == type_nat) {
        const val = leb.readUleb128(u128, reader) catch |e| return mapLebError(e);
        if (val > @as(u128, std.math.maxInt(i128))) return error.Overflow;
        return @intCast(val);
    }

    // reserved accepts any wire type by skipping the value
    if (T == t.Reserved) {
        if (opcode != type_reserved) {
            try skipValue(reader, table, ref);
        }
        return .{};
    }

    if (ref >= 0) {
        if (@as(usize, @intCast(ref)) >= table.len) return error.TypeMismatch;
        return decodeCompound(T, reader, table, table[@intCast(ref)], alloc, data_len, options, cycle_flags);
    }
    return decodePrimitive(T, reader, ref, alloc);
}

fn decodePrimitive(comptime T: type, reader: anytype, opcode: i32, alloc: Allocator) DecodeError!T {
    switch (opcode) {
        type_bool => {
            if (T != bool) return error.TypeMismatch;
            const b = reader.readByte() catch return error.EndOfStream;
            return switch (b) {
                0 => false,
                1 => true,
                else => error.TypeMismatch,
            };
        },
        type_null => {
            if (T != void) return error.TypeMismatch;
            return {};
        },
        type_reserved => {
            if (T != t.Reserved) return error.TypeMismatch;
            return .{};
        },
        type_nat8 => return decodeFixed(T, u8, reader),
        type_nat16 => return decodeFixed(T, u16, reader),
        type_nat32 => return decodeFixed(T, u32, reader),
        type_nat64 => return decodeFixed(T, u64, reader),
        type_int8 => return decodeFixed(T, i8, reader),
        type_int16 => return decodeFixed(T, i16, reader),
        type_int32 => return decodeFixed(T, i32, reader),
        type_int64 => return decodeFixed(T, i64, reader),
        type_nat => {
            if (T != u128) return error.TypeMismatch;
            return leb.readUleb128(u128, reader) catch |e| return mapLebError(e);
        },
        type_int => {
            if (T != i128) return error.TypeMismatch;
            return leb.readIleb128(i128, reader) catch |e| return mapLebError(e);
        },
        type_float32 => return decodeFixed(T, f32, reader),
        type_float64 => return decodeFixed(T, f64, reader),
        type_text => return decodeText(T, reader, alloc),
        type_principal => return decodePrincipal(T, reader, alloc),
        else => return error.UnsupportedType,
    }
}

fn decodeFixed(comptime T: type, comptime Wire: type, reader: anytype) DecodeError!T {
    if (T != Wire) return error.TypeMismatch;
    const size = @divExact(@bitSizeOf(Wire), 8);
    var buf: [size]u8 = undefined;
    reader.readNoEof(&buf) catch return error.EndOfStream;
    const Uint = std.meta.Int(.unsigned, @bitSizeOf(Wire));
    return @bitCast(std.mem.littleToNative(Uint, @bitCast(buf)));
}

fn decodeText(comptime T: type, reader: anytype, alloc: Allocator) DecodeError!T {
    if (comptime !t.isText(T)) return error.TypeMismatch;
    const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    reader.readNoEof(buf) catch return error.EndOfStream;
    if (!std.unicode.utf8ValidateSlice(buf)) return error.InvalidUtf8;
    return buf;
}

fn decodePrincipal(comptime T: type, reader: anytype, alloc: Allocator) DecodeError!T {
    if (T != t.Principal) return error.TypeMismatch;
    return decodePrincipalValue(reader, alloc);
}

fn decodeFunc(comptime T: type, reader: anytype, alloc: Allocator, entry: TypeEntry) DecodeError!T {
    if (comptime !t.isFuncType(T)) return error.TypeMismatch;
    // Validate annotation matches expected
    if (entry.annotations != @intFromEnum(T.annotation)) return error.TypeMismatch;
    const flag = reader.readByte() catch return error.EndOfStream;
    if (flag != 1) return error.UnsupportedPrincipalRef;
    const service = try decodePrincipalValue(reader, alloc);
    errdefer alloc.free(service.bytes);
    const mlen = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    const mbuf = alloc.alloc(u8, mlen) catch return error.OutOfMemory;
    errdefer alloc.free(mbuf);
    reader.readNoEof(mbuf) catch return error.EndOfStream;
    return .{ .service = service, .method = mbuf };
}

fn decodeService(comptime T: type, reader: anytype, alloc: Allocator) DecodeError!T {
    if (T != t.Service) return error.TypeMismatch;
    const flag = reader.readByte() catch return error.EndOfStream;
    if (flag != 1) return error.UnsupportedPrincipalRef;
    const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    reader.readNoEof(buf) catch return error.EndOfStream;
    return .{ .principal = .{ .bytes = buf } };
}

fn decodePrincipalValue(reader: anytype, alloc: Allocator) DecodeError!t.Principal {
    const flag = reader.readByte() catch return error.EndOfStream;
    if (flag != 1) return error.UnsupportedPrincipalRef;
    const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    reader.readNoEof(buf) catch return error.EndOfStream;
    return .{ .bytes = buf };
}

fn decodeCompound(comptime T: type, reader: anytype, table: []const TypeEntry, entry: TypeEntry, alloc: Allocator, data_len: usize, options: DecodeOptions, cycle_flags: []const bool) DecodeError!T {
    switch (entry.opcode) {
        type_opt => {
            if (@typeInfo(T) != .optional) return error.TypeMismatch;
            const flag = reader.readByte() catch return error.EndOfStream;
            if (flag == 0) return null;
            if (flag != 1) return error.TypeMismatch;
            const Child = @typeInfo(T).optional.child;
            if (!isWireCompatible(Child, wireOpcode(table, entry.inner))) {
                try skipValue(reader, table, entry.inner);
                return null;
            }
            return try decodeValue(Child, reader, table, entry.inner, alloc, data_len, options, cycle_flags);
        },
        type_vec => return decodeVec(T, reader, table, entry, alloc, data_len, options, cycle_flags),
        type_record => {
            if (@typeInfo(T) != .@"struct") return error.TypeMismatch;
            return decodeRecord(T, reader, table, entry.fields, alloc, data_len, options, cycle_flags);
        },
        type_variant => {
            if (@typeInfo(T) != .@"union") return error.TypeMismatch;
            return decodeVariant(T, reader, table, entry.fields, alloc, data_len, options, cycle_flags);
        },
        type_func => return decodeFunc(T, reader, alloc, entry),
        type_service => return decodeService(T, reader, alloc),
        else => return error.UnsupportedType,
    }
}

fn decodeVec(comptime T: type, reader: anytype, table: []const TypeEntry, entry: TypeEntry, alloc: Allocator, data_len: usize, options: DecodeOptions, cycle_flags: []const bool) DecodeError!T {
    if (T == t.Blob) {
        const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
        if (len > data_len) return error.EndOfStream;
        const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
        errdefer alloc.free(buf);
        reader.readNoEof(buf) catch return error.EndOfStream;
        return .{ .data = buf };
    }
    if (comptime t.isText(T)) {
        if (entry.inner != type_nat8) return error.TypeMismatch;
        const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
        if (len > data_len) return error.EndOfStream;
        const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
        errdefer alloc.free(buf);
        reader.readNoEof(buf) catch return error.EndOfStream;
        return buf;
    }
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .slice) return error.TypeMismatch;
    const Child = info.pointer.child;
    const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    if (len == 0) {
        const buf = alloc.alloc(Child, 0) catch return error.OutOfMemory;
        return buf;
    }
    // Reject implausible lengths. For non-zero-sized wire elements, each
    // needs at least 1 byte so len cannot exceed data_len. For zero-sized
    // wire types (null, reserved, empty records), use the configurable cap.
    const max_len: usize = if (isZeroSized(table, entry.inner))
        if (options.max_zero_sized_vec_len > 0) options.max_zero_sized_vec_len else std.math.maxInt(u32)
    else
        data_len;
    if (len > max_len) return error.EndOfStream;
    const buf = alloc.alloc(Child, len) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    var decoded_count: usize = 0;
    errdefer for (buf[0..decoded_count]) |item| {
        freeDecoded(Child, alloc, item);
    };
    for (buf) |*elem| {
        elem.* = try decodeValue(Child, reader, table, entry.inner, alloc, data_len, options, cycle_flags);
        decoded_count += 1;
    }
    return buf;
}

fn decodeRecord(
    comptime T: type,
    reader: anytype,
    table: []const TypeEntry,
    wire_fields: []const FieldEntry,
    alloc: Allocator,
    data_len: usize,
    options: DecodeOptions,
    cycle_flags: []const bool,
) DecodeError!T {
    const zig_fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;
    var found = [_]bool{false} ** zig_fields.len;
    errdefer inline for (zig_fields, 0..) |zf, i| {
        if (found[i]) {
            freeDecoded(zf.type, alloc, @field(result, zf.name));
        }
    };

    for (wire_fields) |wf| {
        if (wf.type_ref >= 0 and @as(usize, @intCast(wf.type_ref)) < cycle_flags.len) {
            if (cycle_flags[@intCast(wf.type_ref)]) return error.EndOfStream;
        }
        var matched = false;
        inline for (zig_fields, 0..) |zf, i| {
            const expected_id = comptime if (@typeInfo(T).@"struct".is_tuple) @as(u32, i) else t.fieldHash(zf.name);
            if (wf.hash == expected_id) {
                @field(result, zf.name) = try decodeValue(zf.type, reader, table, wf.type_ref, alloc, data_len, options, cycle_flags);
                found[i] = true;
                matched = true;
            }
        }
        if (!matched) {
            try skipValue(reader, table, wf.type_ref);
        }
    }

    inline for (zig_fields, 0..) |zf, i| {
        if (!found[i]) {
            if (@typeInfo(zf.type) == .optional) {
                @field(result, zf.name) = null;
            } else if (zf.default_value_ptr) |ptr| {
                const default: *const zf.type = @ptrCast(@alignCast(ptr));
                @field(result, zf.name) = default.*;
            } else {
                return error.MissingField;
            }
        }
    }

    return result;
}

fn decodeVariant(
    comptime T: type,
    reader: anytype,
    table: []const TypeEntry,
    wire_fields: []const FieldEntry,
    alloc: Allocator,
    data_len: usize,
    options: DecodeOptions,
    cycle_flags: []const bool,
) DecodeError!T {
    const idx = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
    if (idx >= wire_fields.len) return error.InvalidVariantIndex;
    const active = wire_fields[idx];

    if (active.type_ref >= 0 and @as(usize, @intCast(active.type_ref)) < cycle_flags.len) {
        if (cycle_flags[@intCast(active.type_ref)]) return error.EndOfStream;
    }

    inline for (@typeInfo(T).@"union".fields) |uf| {
        if (active.hash == comptime t.fieldHash(uf.name)) {
            if (uf.type == void) {
                if (wireOpcode(table, active.type_ref) != type_null)
                    return error.TypeMismatch;
                return @unionInit(T, uf.name, {});
            } else {
                return @unionInit(T, uf.name, try decodeValue(uf.type, reader, table, active.type_ref, alloc, data_len, options, cycle_flags));
            }
        }
    }

    return error.UnknownVariant;
}

fn isZeroSized(table: []const TypeEntry, ref: i32) bool {
    return isZeroSizedDepth(table, ref, 0);
}

fn isZeroSizedDepth(table: []const TypeEntry, ref: i32, depth: usize) bool {
    if (depth > max_depth) return false;
    if (ref >= 0) {
        if (@as(usize, @intCast(ref)) >= table.len) return false;
        const entry = table[@intCast(ref)];
        return switch (entry.opcode) {
            // A record is zero-sized only when all its fields are zero-sized.
            type_record => blk: {
                for (entry.fields) |f| {
                    if (!isZeroSizedDepth(table, f.type_ref, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            // vec/opt/variant always encode at least a length/tag byte on the
            // wire, so they are never zero-sized even if the inner type is.
            else => entry.opcode == type_null or entry.opcode == type_reserved,
        };
    }
    return ref == type_null or ref == type_reserved;
}

// Returns the length of the longest prefix of `buf` that is valid UTF-8
// ending on a complete codepoint boundary. Trailing bytes of an incomplete
// multi-byte sequence are excluded so they can be carried to the next chunk.
fn validUtf8Prefix(buf: []const u8) usize {
    if (std.unicode.utf8ValidateSlice(buf)) return buf.len;
    // Find the last position where a valid codepoint could start.
    // Walk backwards to find the start of the trailing incomplete sequence.
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        // Check if this byte is a leading byte (not a continuation 10xxxxxx).
        if (buf[i] & 0xC0 != 0x80) {
            // This is a leading byte. Check if buf[0..i] is valid.
            if (i == 0) return 0;
            if (std.unicode.utf8ValidateSlice(buf[0..i])) return i;
            // buf[0..i] is also invalid, so there's a real encoding error.
            return 0;
        }
    }
    return 0;
}

fn skipValue(reader: anytype, table: []const TypeEntry, ref: i32) DecodeError!void {
    return skipValueDepth(reader, table, ref, 0);
}

const max_depth = 256;

fn skipValueDepth(reader: anytype, table: []const TypeEntry, ref: i32, depth: usize) DecodeError!void {
    if (depth > max_depth) return error.TypeMismatch;
    if (ref >= 0) {
        if (@as(usize, @intCast(ref)) >= table.len) return error.TypeMismatch;
        const entry = table[@intCast(ref)];
        switch (entry.opcode) {
            type_opt => {
                const flag = reader.readByte() catch return error.EndOfStream;
                if (flag == 0) return;
                if (flag != 1) return error.TypeMismatch;
                try skipValueDepth(reader, table, entry.inner, depth + 1);
            },
            type_vec => {
                const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                if (!isZeroSized(table, entry.inner)) {
                    for (0..len) |_| try skipValueDepth(reader, table, entry.inner, depth + 1);
                }
            },
            type_record => {
                for (entry.fields) |f| try skipValueDepth(reader, table, f.type_ref, depth + 1);
            },
            type_variant => {
                const vi = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                if (vi < entry.fields.len) try skipValueDepth(reader, table, entry.fields[vi].type_ref, depth + 1);
            },
            type_func => {
                const flag = reader.readByte() catch return error.EndOfStream;
                if (flag == 1) {
                    const pf = reader.readByte() catch return error.EndOfStream;
                    if (pf == 1) {
                        const pl = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                        reader.skipBytes(pl, .{}) catch return error.EndOfStream;
                    }
                    const ml = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                    reader.skipBytes(ml, .{}) catch return error.EndOfStream;
                }
            },
            type_service => {
                const flag = reader.readByte() catch return error.EndOfStream;
                if (flag == 1) {
                    const pl = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                    reader.skipBytes(pl, .{}) catch return error.EndOfStream;
                }
            },
            else => {
                // Future types (opcode < -24): value is two LEB128 counts
                // m and n, followed by m data bytes and n type references.
                // See https://github.com/dfinity/candid/blob/master/spec/Candid.md
                const m = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                const n = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                reader.skipBytes(m, .{}) catch return error.EndOfStream;
                for (0..n) |_| {
                    const ref_idx = leb.readIleb128(i32, reader) catch |e| return mapLebError(e);
                    try skipValueDepth(reader, table, ref_idx, depth + 1);
                }
            },
        }
        return;
    }
    switch (ref) {
        type_null, type_reserved => {},
        type_bool => {
            const b = reader.readByte() catch return error.EndOfStream;
            if (b > 1) return error.TypeMismatch;
        },
        type_nat8, type_int8 => {
            _ = reader.readByte() catch return error.EndOfStream;
        },
        type_nat16, type_int16 => reader.skipBytes(2, .{}) catch return error.EndOfStream,
        type_nat32, type_int32, type_float32 => reader.skipBytes(4, .{}) catch return error.EndOfStream,
        type_nat64, type_int64, type_float64 => reader.skipBytes(8, .{}) catch return error.EndOfStream,
        type_nat => {
            _ = leb.readUleb128(u128, reader) catch |e| return mapLebError(e);
        },
        type_int => {
            _ = leb.readIleb128(i128, reader) catch |e| return mapLebError(e);
        },
        type_text => {
            const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
            var remaining: usize = len;
            var carry: usize = 0;
            var buf: [256]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, buf.len - carry);
                const slice = buf[carry..][0..to_read];
                reader.readNoEof(slice) catch return error.EndOfStream;
                const filled = carry + to_read;
                const valid_end = validUtf8Prefix(buf[0..filled]);
                if (valid_end == 0 and filled >= 4) return error.InvalidUtf8;
                carry = filled - valid_end;
                if (carry > 0) {
                    std.mem.copyForwards(u8, buf[0..carry], buf[valid_end..filled]);
                }
                remaining -= to_read;
            }
            if (carry > 0) return error.InvalidUtf8;
        },
        type_principal => {
            const flag = reader.readByte() catch return error.EndOfStream;
            if (flag == 1) {
                const len = leb.readUleb128(u32, reader) catch |e| return mapLebError(e);
                reader.skipBytes(len, .{}) catch return error.EndOfStream;
            }
        },
        else => return error.UnsupportedType,
    }
}

const testing = std.testing;
const encode = @import("encoding.zig").encode;

test "round-trip record" {
    const Rec = struct { age: u8, name: []const u8 };
    const bytes = try encode(testing.allocator, .{Rec{ .age = 30, .name = "Alice" }});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Rec, testing.allocator, bytes);
    defer testing.allocator.free(decoded.name);
    try testing.expectEqual(@as(u8, 30), decoded.age);
    try testing.expectEqualStrings("Alice", decoded.name);
}

test "round-trip optional" {
    const present = try encode(testing.allocator, .{@as(?u32, 12345)});
    defer testing.allocator.free(present);
    try testing.expectEqual(@as(?u32, 12345), try decode(?u32, testing.allocator, present));

    const absent = try encode(testing.allocator, .{@as(?u32, null)});
    defer testing.allocator.free(absent);
    try testing.expectEqual(@as(?u32, null), try decode(?u32, testing.allocator, absent));
}

test "round-trip variant" {
    const Mode = union(enum) { install: void, reinstall: void, upgrade: void };
    const val: Mode = .install;
    const bytes = try encode(testing.allocator, .{val});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Mode, testing.allocator, bytes);
    try testing.expectEqual(val, decoded);
}

test "round-trip vec" {
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const bytes = try encode(testing.allocator, .{@as([]const u32, &items)});
    defer testing.allocator.free(bytes);
    const decoded = try decode([]const u32, testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u32, &items, decoded);
}

test "round-trip principal" {
    const id = [_]u8{ 0xAB, 0xCD, 0x01 };
    const bytes = try encode(testing.allocator, .{t.Principal.from(&id)});
    defer testing.allocator.free(bytes);
    const decoded = try decode(t.Principal, testing.allocator, bytes);
    defer testing.allocator.free(decoded.bytes);
    try testing.expectEqualSlices(u8, &id, decoded.bytes);
}

test "round-trip blob" {
    const data = [_]u8{ 0xFF, 0x00, 0x42 };
    const bytes = try encode(testing.allocator, .{t.Blob.from(&data)});
    defer testing.allocator.free(bytes);
    const decoded = try decode(t.Blob, testing.allocator, bytes);
    defer testing.allocator.free(decoded.data);
    try testing.expectEqualSlices(u8, &data, decoded.data);
}

test "round-trip nested record with optional" {
    const Inner = struct { x: u32 };
    const Outer = struct { inner: ?Inner, label: []const u8 };
    const bytes = try encode(testing.allocator, .{Outer{ .inner = .{ .x = 99 }, .label = "test" }});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Outer, testing.allocator, bytes);
    defer testing.allocator.free(decoded.label);
    try testing.expectEqual(@as(u32, 99), decoded.inner.?.x);
    try testing.expectEqualStrings("test", decoded.label);
}

test "decode with extra wire fields" {
    const Full = struct { age: u8, name: []const u8, extra: u32 };
    const bytes = try encode(testing.allocator, .{Full{ .age = 25, .name = "Bob", .extra = 999 }});
    defer testing.allocator.free(bytes);
    const Partial = struct { age: u8, name: []const u8 };
    const decoded = try decode(Partial, testing.allocator, bytes);
    defer testing.allocator.free(decoded.name);
    try testing.expectEqual(@as(u8, 25), decoded.age);
    try testing.expectEqualStrings("Bob", decoded.name);
}

test "round-trip decodeMany multiple args" {
    const bytes = try encode(testing.allocator, .{ @as(u32, 42), @as([]const u8, "hello"), true });
    defer testing.allocator.free(bytes);
    const result = try decodeMany(struct { u32, []const u8, bool }, testing.allocator, bytes);
    defer testing.allocator.free(result[1]);
    try testing.expectEqual(@as(u32, 42), result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqual(true, result[2]);
}

test "decodeMany with fewer args than wire" {
    const bytes = try encode(testing.allocator, .{ @as(u32, 7), @as(u8, 3) });
    defer testing.allocator.free(bytes);
    const result = try decodeMany(struct { u32 }, testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 7), result[0]);
}

test "coerce nat wire to int expected" {
    const bytes = try encode(testing.allocator, .{@as(u128, 42)});
    defer testing.allocator.free(bytes);
    const val = try decode(i128, testing.allocator, bytes);
    try testing.expectEqual(@as(i128, 42), val);
}

test "coerce null wire to opt T" {
    const bytes = try encode(testing.allocator, .{@as(void, {})});
    defer testing.allocator.free(bytes);
    const val = try decode(?u32, testing.allocator, bytes);
    try testing.expectEqual(@as(?u32, null), val);
}

test "coerce reserved wire to opt T" {
    const bytes = try encode(testing.allocator, .{t.Reserved{}});
    defer testing.allocator.free(bytes);
    const val = try decode(?u32, testing.allocator, bytes);
    try testing.expectEqual(@as(?u32, null), val);
}

test "coerce non-optional wire to opt T" {
    const bytes = try encode(testing.allocator, .{@as(u32, 123)});
    defer testing.allocator.free(bytes);
    const val = try decode(?u32, testing.allocator, bytes);
    try testing.expectEqual(@as(?u32, 123), val);
}

test "coerce non-optional text wire to opt text" {
    const bytes = try encode(testing.allocator, .{@as([]const u8, "hello")});
    defer testing.allocator.free(bytes);
    const val = try decode(?[]const u8, testing.allocator, bytes);
    try testing.expect(val != null);
    defer testing.allocator.free(val.?);
    try testing.expectEqualStrings("hello", val.?);
}

test "coerce incompatible wire to opt T produces null" {
    const bytes = try encode(testing.allocator, .{true});
    defer testing.allocator.free(bytes);
    const val = try decode(?u32, testing.allocator, bytes);
    try testing.expectEqual(@as(?u32, null), val);
}

test "coerce non-optional record wire to opt record" {
    const Rec = struct { x: u32 };
    const bytes = try encode(testing.allocator, .{Rec{ .x = 77 }});
    defer testing.allocator.free(bytes);
    const val = try decode(?Rec, testing.allocator, bytes);
    try testing.expect(val != null);
    try testing.expectEqual(@as(u32, 77), val.?.x);
}

test "round-trip tuple as positional record" {
    const Tuple = struct { u32, []const u8 };
    const val: Tuple = .{ 42, "hello" };
    const bytes = try encode(testing.allocator, .{val});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Tuple, testing.allocator, bytes);
    defer testing.allocator.free(decoded[1]);
    try testing.expectEqual(@as(u32, 42), decoded[0]);
    try testing.expectEqualStrings("hello", decoded[1]);
}

test "tuple uses numeric field IDs 0 1 2" {
    const Tuple = struct { u8, u8, u8 };
    const val: Tuple = .{ 10, 20, 30 };
    const bytes = try encode(testing.allocator, .{val});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Tuple, testing.allocator, bytes);
    try testing.expectEqual(@as(u8, 10), decoded[0]);
    try testing.expectEqual(@as(u8, 20), decoded[1]);
    try testing.expectEqual(@as(u8, 30), decoded[2]);
}

test "decode numeric-ID record into tuple" {
    const bytes = try encode(testing.allocator, .{@as(struct { u32, bool }, .{ 99, true })});
    defer testing.allocator.free(bytes);
    const decoded = try decode(struct { u32, bool }, testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 99), decoded[0]);
    try testing.expectEqual(true, decoded[1]);
}

test "decodeVec frees partial elements on error" {
    // Encode a vec of 3 text strings, then truncate so the 3rd element
    // fails mid-decode. The testing allocator will flag any leaked
    // allocations from the first two successfully-decoded strings.
    const items = [_][]const u8{ "hello", "world", "!" };
    const bytes = try encode(testing.allocator, .{@as([]const []const u8, &items)});
    defer testing.allocator.free(bytes);

    // Truncate the last byte so the third string read hits EndOfStream.
    const truncated = bytes[0 .. bytes.len - 1];
    const result = decode([]const []const u8, testing.allocator, truncated);
    try testing.expectError(error.EndOfStream, result);
    // If partially-decoded elements were leaked, the testing allocator
    // will fail this test at cleanup.
}

test "decodeRecord frees partial fields on error" {
    // Encode a record with two text fields, then truncate so the second
    // field fails mid-decode. The testing allocator will detect any leak
    // from the first successfully-decoded field.
    const Rec = struct { first: []const u8, second: []const u8 };
    const bytes = try encode(testing.allocator, .{Rec{ .first = "hello", .second = "world" }});
    defer testing.allocator.free(bytes);

    const truncated = bytes[0 .. bytes.len - 1];
    const result = decode(Rec, testing.allocator, truncated);
    try testing.expectError(error.EndOfStream, result);
}

test "skipValue validates utf8 in text without reader internals" {
    // Encode a record with a text field that gets skipped (wire has extra
    // field not in the Zig type). Use a 300-byte string to exercise the
    // chunked UTF-8 validation path (buffer is 256 bytes).
    const long_text = "a" ** 300;
    const Wire = struct { keep: u32, extra: []const u8 };
    const bytes = try encode(testing.allocator, .{Wire{ .keep = 42, .extra = long_text }});
    defer testing.allocator.free(bytes);

    // Decode as a struct missing the "extra" field. The text value is
    // skipped via skipValue which must validate UTF-8 in chunks.
    const Small = struct { keep: u32 };
    const decoded = try decode(Small, testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 42), decoded.keep);
}

test "Decoded deinit frees all nested allocations" {
    const Rec = struct { name: []const u8, tags: []const []const u8 };
    const bytes = try encode(testing.allocator, .{Rec{
        .name = "Alice",
        .tags = &[_][]const u8{ "admin", "user" },
    }});
    defer testing.allocator.free(bytes);

    var result = try decodeOwned(Rec, testing.allocator, bytes);
    defer result.deinit();
    try testing.expectEqualStrings("Alice", result.value.name);
    try testing.expectEqual(@as(usize, 2), result.value.tags.len);
    try testing.expectEqualStrings("admin", result.value.tags[0]);
    try testing.expectEqualStrings("user", result.value.tags[1]);
}
