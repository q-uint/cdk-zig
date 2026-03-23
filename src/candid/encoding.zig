const std = @import("std");
const leb = std.leb;
const Allocator = std.mem.Allocator;
const List = std.array_list.AlignedManaged(u8, null);
const t = @import("types.zig");

pub const empty_args: []const u8 = &[_]u8{ 'D', 'I', 'D', 'L', 0x00, 0x00 };

pub fn encode(alloc: Allocator, args: anytype) ![]const u8 {
    const ArgsType = @TypeOf(args);
    const info = @typeInfo(ArgsType);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("args must be a tuple, e.g. .{value1, value2}");

    const header = comptime buildHeader(ArgsType);

    var list = List.init(alloc);
    errdefer list.deinit();
    try list.appendSlice(header);

    const writer = list.writer();
    inline for (info.@"struct".fields) |field| {
        try encodeValue(writer, field.type, @field(args, field.name));
    }

    return list.toOwnedSlice();
}

fn encodeValue(writer: anytype, comptime T: type, value: T) Allocator.Error!void {
    if (T == t.Principal) {
        try writer.writeByte(1);
        try leb.writeUleb128(writer, @as(u32, @intCast(value.bytes.len)));
        return writer.writeAll(value.bytes);
    }
    if (T == t.Blob) {
        try leb.writeUleb128(writer, @as(u32, @intCast(value.data.len)));
        return writer.writeAll(value.data);
    }
    if (comptime t.isFuncType(T)) {
        try writer.writeByte(1);
        try writer.writeByte(1);
        try leb.writeUleb128(writer, @as(u32, @intCast(value.service.bytes.len)));
        try writer.writeAll(value.service.bytes);
        try leb.writeUleb128(writer, @as(u32, @intCast(value.method.len)));
        return writer.writeAll(value.method);
    }
    if (T == t.Service) {
        try writer.writeByte(1);
        try leb.writeUleb128(writer, @as(u32, @intCast(value.principal.bytes.len)));
        return writer.writeAll(value.principal.bytes);
    }
    if (T == t.Reserved) return;

    switch (@typeInfo(T)) {
        .bool => return writer.writeByte(if (value) 1 else 0),
        .void => return,
        .int => |info| switch (info.signedness) {
            .unsigned => switch (info.bits) {
                8 => return writer.writeByte(value),
                16 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, value))),
                32 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, value))),
                64 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u64, value))),
                128 => return leb.writeUleb128(writer, value),
                else => @compileError("unsupported int width"),
            },
            .signed => switch (info.bits) {
                8 => return writer.writeByte(@bitCast(value)),
                16 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u16, @bitCast(value)))),
                32 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(value)))),
                64 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(value)))),
                128 => return leb.writeIleb128(writer, value),
                else => @compileError("unsupported int width"),
            },
        },
        .float => |info| switch (info.bits) {
            32 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(value)))),
            64 => return writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(value)))),
            else => @compileError("unsupported float width"),
        },
        .optional => |o| {
            if (value) |v| {
                try writer.writeByte(1);
                return encodeValue(writer, o.child, v);
            } else {
                return writer.writeByte(0);
            }
        },
        .pointer => |p| {
            if (p.size == .one) {
                return encodeValue(writer, p.child, value.*);
            }
            if (p.size != .slice) @compileError("unsupported pointer type: " ++ @typeName(T));
            if (p.child == u8) {
                try leb.writeUleb128(writer, @as(u32, @intCast(value.len)));
                return writer.writeAll(value);
            }
            try leb.writeUleb128(writer, @as(u32, @intCast(value.len)));
            for (value) |elem| {
                try encodeValue(writer, p.child, elem);
            }
        },
        .@"struct" => {
            const sorted = comptime t.sortedStructFields(T);
            inline for (sorted) |f| {
                try encodeValue(writer, f.field_type, @field(value, f.name));
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |payload, tag| {
                    const sorted = comptime t.sortedUnionFields(T);
                    const idx: u32 = comptime blk: {
                        for (sorted, 0..) |sf, i| {
                            if (std.mem.eql(u8, @tagName(tag), sf.name))
                                break :blk @intCast(i);
                        }
                        unreachable;
                    };
                    try leb.writeUleb128(writer, idx);
                    if (@TypeOf(payload) != void) {
                        try encodeValue(writer, @TypeOf(payload), payload);
                    }
                },
            }
        },
        else => @compileError("unsupported candid type: " ++ @typeName(T)),
    }
}

fn buildHeader(comptime ArgsType: type) []const u8 {
    comptime {
        const fields = @typeInfo(ArgsType).@"struct".fields;

        var compound: []const type = &.{};
        for (fields) |f| {
            compound = collectCompound(f.type, compound);
        }

        var bytes: []const u8 = "DIDL";
        bytes = bytes ++ t.ulebComptime(compound.len);

        for (compound) |ct| {
            bytes = bytes ++ typeDef(ct, compound);
        }

        bytes = bytes ++ t.ulebComptime(fields.len);
        for (fields) |f| {
            bytes = bytes ++ t.slebComptime(typeRef(f.type, compound));
        }

        return bytes;
    }
}

fn collectCompound(comptime T: type, comptime existing: []const type) []const type {
    if (T == t.Blob or comptime t.isFuncType(T) or T == t.Service) return appendType(existing, T);
    if (T == t.Principal or T == t.Reserved or T == void or T == bool) return existing;
    if (comptime t.isText(T)) return existing;
    if (comptime t.isPrimitive(T)) return existing;

    switch (@typeInfo(T)) {
        .optional => |o| {
            const result = collectCompound(o.child, existing);
            return appendType(result, T);
        },
        .pointer => |p| {
            if (p.size == .slice) {
                const result = collectCompound(p.child, existing);
                return appendType(result, T);
            }
            if (p.size == .one) {
                return collectCompound(p.child, existing);
            }
            return existing;
        },
        .@"struct" => |s| {
            var result = appendType(existing, T);
            if (result.len == existing.len) return result;
            for (s.fields) |f| result = collectCompound(f.type, result);
            return result;
        },
        .@"union" => |u_info| {
            var result = appendType(existing, T);
            if (result.len == existing.len) return result;
            for (u_info.fields) |f| {
                if (f.type != void) result = collectCompound(f.type, result);
            }
            return result;
        },
        else => return existing,
    }
}

fn appendType(comptime existing: []const type, comptime T: type) []const type {
    for (existing) |ct| {
        if (ct == T) return existing;
    }
    return existing ++ &[_]type{T};
}

fn typeDef(comptime T: type, comptime table: []const type) []const u8 {
    if (T == t.Blob) return t.slebComptime(t.type_vec) ++ t.slebComptime(t.type_nat8);
    if (comptime t.isFuncType(T)) {
        const ann = @intFromEnum(T.annotation);
        return t.slebComptime(t.type_func) ++ t.ulebComptime(0) ++ t.ulebComptime(0) ++
            if (ann != 0) t.ulebComptime(1) ++ t.ulebComptime(ann) else t.ulebComptime(0);
    }
    if (T == t.Service) return t.slebComptime(t.type_service) ++ t.ulebComptime(0);

    switch (@typeInfo(T)) {
        .optional => |o| return t.slebComptime(t.type_opt) ++ t.slebComptime(typeRef(o.child, table)),
        .pointer => |p| return t.slebComptime(t.type_vec) ++ t.slebComptime(typeRef(p.child, table)),
        .@"struct" => {
            const sorted = t.sortedStructFields(T);
            var bytes: []const u8 = t.slebComptime(t.type_record) ++ t.ulebComptime(sorted.len);
            for (sorted) |sf| {
                bytes = bytes ++ t.ulebComptime(sf.hash) ++ t.slebComptime(typeRef(sf.field_type, table));
            }
            return bytes;
        },
        .@"union" => {
            const sorted = t.sortedUnionFields(T);
            var bytes: []const u8 = t.slebComptime(t.type_variant) ++ t.ulebComptime(sorted.len);
            for (sorted) |sf| {
                bytes = bytes ++ t.ulebComptime(sf.hash) ++ t.slebComptime(typeRef(sf.field_type, table));
            }
            return bytes;
        },
        else => unreachable,
    }
}

fn typeRef(comptime T: type, comptime table: []const type) i32 {
    if (T == void) return t.type_null;
    if (T == t.Reserved) return t.type_reserved;
    if (T == t.Principal) return t.type_principal;

    switch (@typeInfo(T)) {
        .bool => return t.type_bool,
        .int => |info| return switch (info.signedness) {
            .unsigned => switch (info.bits) {
                8 => t.type_nat8,
                16 => t.type_nat16,
                32 => t.type_nat32,
                64 => t.type_nat64,
                128 => t.type_nat,
                else => @compileError("unsupported int width"),
            },
            .signed => switch (info.bits) {
                8 => t.type_int8,
                16 => t.type_int16,
                32 => t.type_int32,
                64 => t.type_int64,
                128 => t.type_int,
                else => @compileError("unsupported int width"),
            },
        },
        .float => |info| return switch (info.bits) {
            32 => t.type_float32,
            64 => t.type_float64,
            else => @compileError("unsupported float width"),
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return t.type_text;
            if (p.size == .one) return typeRef(p.child, table);
            return tableIndex(T, table);
        },
        else => return tableIndex(T, table),
    }
}

fn tableIndex(comptime T: type, comptime table: []const type) i32 {
    for (table, 0..) |ct, i| {
        if (ct == T) return @intCast(i);
    }
    @compileError("type not in table: " ++ @typeName(T));
}

const testing = std.testing;
const decode = @import("decoding.zig").decode;

test "encode empty args" {
    const bytes = try encode(testing.allocator, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 'D', 'I', 'D', 'L', 0x00, 0x00 }, bytes);
}

test "encode single nat32" {
    const bytes = try encode(testing.allocator, .{@as(u32, 42)});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I',  'D',  'L',
        0x00, 0x01, 0x79, 0x2a,
        0x00, 0x00, 0x00,
    }, bytes);
}

test "encode bool" {
    const bytes = try encode(testing.allocator, .{true});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 'D', 'I', 'D', 'L', 0x00, 0x01, 0x7e, 0x01 }, bytes);
}

test "encode text" {
    const bytes = try encode(testing.allocator, .{@as([]const u8, "hello")});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I', 'D', 'L', 0x00, 0x01, 0x71,
        0x05, 'h', 'e', 'l', 'l',  'o',
    }, bytes);
}

test "encode optional" {
    const present = try encode(testing.allocator, .{@as(?u8, 42)});
    defer testing.allocator.free(present);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I',  'D', 'L', 0x01, 0x6e, 0x7b, 0x01, 0x00,
        0x01, 0x2a,
    }, present);

    const absent = try encode(testing.allocator, .{@as(?u8, null)});
    defer testing.allocator.free(absent);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I', 'D', 'L', 0x01, 0x6e, 0x7b, 0x01, 0x00,
        0x00,
    }, absent);
}

test "encode record" {
    const Rec = struct { age: u8, name: []const u8 };
    const bytes = try encode(testing.allocator, .{Rec{ .age = 30, .name = "Alice" }});
    defer testing.allocator.free(bytes);
    const decoded = try decode(Rec, testing.allocator, bytes);
    defer testing.allocator.free(decoded.name);
    try testing.expectEqual(@as(u8, 30), decoded.age);
    try testing.expectEqualStrings("Alice", decoded.name);
}

test "encode principal" {
    const p = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const bytes = try encode(testing.allocator, .{t.Principal.from(&p)});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I',  'D',  'L',  0x00, 0x01, 0x68,
        0x01, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x01, 0x01,
    }, bytes);
}

test "encode blob" {
    const bytes = try encode(testing.allocator, .{t.Blob.from(&[_]u8{ 1, 2, 3 })});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I', 'D', 'L', 0x01, 0x6d, 0x7b, 0x01, 0x00,
        0x03, 1,   2,   3,
    }, bytes);
}

test "round-trip recursive type (linked list)" {
    const Node = struct {
        value: u32,
        next: ?*const @This(),
    };

    const leaf = Node{ .value = 3, .next = null };
    const mid = Node{ .value = 2, .next = &leaf };
    const head = Node{ .value = 1, .next = &mid };

    const bytes = try encode(testing.allocator, .{head});
    defer testing.allocator.free(bytes);

    const decoded = try decode(Node, testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 1), decoded.value);
    try testing.expect(decoded.next != null);
    try testing.expectEqual(@as(u32, 2), decoded.next.?.value);
    try testing.expect(decoded.next.?.next != null);
    try testing.expectEqual(@as(u32, 3), decoded.next.?.next.?.value);
    try testing.expectEqual(@as(?*const Node, null), decoded.next.?.next.?.next);

    // Clean up allocated pointers (decoder allocates them).
    testing.allocator.destroy(decoded.next.?.next.?);
    testing.allocator.destroy(decoded.next.?);
}

test "round-trip recursive type with optional null leaf" {
    const Node = struct {
        value: u32,
        next: ?*const @This(),
    };

    const single = Node{ .value = 42, .next = null };
    const bytes = try encode(testing.allocator, .{single});
    defer testing.allocator.free(bytes);

    const decoded = try decode(Node, testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 42), decoded.value);
    try testing.expectEqual(@as(?*const Node, null), decoded.next);
}

test "round-trip recursive variant (tree)" {
    const Tree = union(enum) {
        const Self = @This();
        leaf: u32,
        node: struct { left: *const Self, right: *const Self },
    };

    const left = Tree{ .leaf = 1 };
    const right = Tree{ .leaf = 2 };
    const root = Tree{ .node = .{ .left = &left, .right = &right } };

    const bytes = try encode(testing.allocator, .{root});
    defer testing.allocator.free(bytes);

    const decoded = try decode(Tree, testing.allocator, bytes);
    try testing.expectEqual(Tree.node, std.meta.activeTag(decoded));
    try testing.expectEqual(@as(u32, 1), decoded.node.left.leaf);
    try testing.expectEqual(@as(u32, 2), decoded.node.right.leaf);

    testing.allocator.destroy(decoded.node.left);
    testing.allocator.destroy(decoded.node.right);
}

test "round-trip func" {
    const pid = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const f = t.Func.from(t.Principal.from(&pid), "greet");
    const bytes = try encode(testing.allocator, .{f});
    defer testing.allocator.free(bytes);

    const decoded = try decode(t.Func, testing.allocator, bytes);
    defer testing.allocator.free(decoded.service.bytes);
    defer testing.allocator.free(decoded.method);
    try testing.expectEqualSlices(u8, &pid, decoded.service.bytes);
    try testing.expectEqualStrings("greet", decoded.method);
}

test "round-trip service" {
    const pid = [_]u8{ 0xAB, 0xCD, 0x01 };
    const svc = t.Service.from(t.Principal.from(&pid));
    const bytes = try encode(testing.allocator, .{svc});
    defer testing.allocator.free(bytes);

    const decoded = try decode(t.Service, testing.allocator, bytes);
    defer testing.allocator.free(decoded.principal.bytes);
    try testing.expectEqualSlices(u8, &pid, decoded.principal.bytes);
}

test "encode nat (u128)" {
    const bytes = try encode(testing.allocator, .{@as(u128, 624485)});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{
        'D',  'I',  'D',  'L', 0x00, 0x01, 0x7d,
        0xe5, 0x8e, 0x26,
    }, bytes);
}
