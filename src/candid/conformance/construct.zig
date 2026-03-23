// Conformance tests: construct.test.did
// https://github.com/dfinity/candid/blob/master/test/construct.test.did

const lib = @import("lib.zig");
const std = @import("std");
const testing = lib.testing;
const x = lib.x;
const decode = lib.decode;
const decodeMany = lib.decodeMany;
const Blob = lib.Blob;
const Reserved = lib.Reserved;
const Empty = lib.Empty;
const RecursiveOpt = lib.RecursiveOpt;
const expectDecodeError = lib.expectDecodeError;
const expectDecodeManyError = lib.expectDecodeManyError;

// -- type table --

test "construct: empty table" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\00\\00"));
}

test "construct: unused type" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\01\\6e\\6f\\00"));
}

test "construct: repeated types" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\02\\6e\\6f\\6e\\6f\\00"));
}

test "construct: recursive type" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\01\\6e\\00\\00"));
}

test "construct: type too short" {
    try expectDecodeManyError(struct {}, error.EndOfStream, comptime x("DIDL\\01\\6e\\00"));
}

test "construct: vacuous type" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\00\\00"));
}

test "construct: vacuous type 2" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\02\\6e\\01\\00\\00"));
}

test "construct: table entry out of range" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\6e\\01\\00"));
}

test "construct: arg entry out of range" {
    try expectDecodeManyError(struct {}, error.TypeMismatch, comptime x("DIDL\\00\\01\\00"));
}

test "construct: arg too short" {
    try expectDecodeManyError(struct {}, error.EndOfStream, comptime x("DIDL\\00\\03\\7f\\7f"));
}

test "construct: arg too long" {
    try expectDecodeManyError(struct {}, error.TrailingBytes, comptime x("DIDL\\00\\02\\7f\\7f\\7f"));
}

test "construct: non-primitive in arg list" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\00\\01\\6e\\7f\\00"));
}

test "construct: primitive type in the table" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\7f\\00"));
}

test "construct: principal in the table" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\68\\00"));
}

test "construct: table entry in the table" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\02\\6d\\7f\\00\\00"));
}

test "construct: table entry in the table (self-reference)" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\00\\00"));
}

test "construct: table too long" {
    try expectDecodeManyError(struct {}, error.EndOfStream, comptime x("DIDL\\01\\6e\\6f\\6e\\6f\\00"));
}

// -- opt --

test "construct: opt int null" {
    try testing.expectEqual(@as(?i128, null), try decode(?i128, testing.allocator, comptime x("DIDL\\01\\6e\\7c\\01\\00\\00")));
}

test "construct: opt type out of range" {
    try expectDecodeError(?i128, error.UnsupportedType, comptime x("DIDL\\01\\6e\\02\\01\\00\\00"));
}

test "construct: opt int 42" {
    try testing.expectEqual(@as(?i128, 42), try decode(?i128, testing.allocator, comptime x("DIDL\\01\\6e\\7c\\01\\00\\01\\2a")));
}

test "construct: opt out of range 0x02" {
    try expectDecodeError(?i128, error.TypeMismatch, comptime x("DIDL\\01\\6e\\7c\\01\\00\\02\\2a"));
}

test "construct: opt out of range 0xff" {
    try expectDecodeError(?i128, error.TypeMismatch, comptime x("DIDL\\01\\6e\\7c\\01\\00\\ff"));
}

test "construct: opt too short" {
    try expectDecodeError(?i128, error.EndOfStream, comptime x("DIDL\\01\\6e\\7c\\01\\00\\01"));
}

test "construct: opt too long" {
    try expectDecodeError(?i128, error.TrailingBytes, comptime x("DIDL\\01\\6e\\7c\\01\\00\\00\\2a"));
}

test "construct: opt nested" {
    const val = try decode(??i128, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7c\\01\\00\\01\\01\\2a"));
    try testing.expectEqual(@as(i128, 42), val.?.?);
}

test "construct: opt recursion" {
    const val = try decode(??void, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\01\\01\\00"));
    try testing.expectEqual(@as(?void, null), val.?);
}

test "construct: opt non-recursive type" {
    const val = try decode(??void, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\01\\01\\00"));
    try testing.expectEqual(@as(?void, null), val.?);
}

test "construct: opt mutual recursion" {
    const val = try decode(??void, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\00\\01\\00\\01\\01\\00"));
    try testing.expectEqual(@as(?void, null), val.?);
}

test "construct: opt extra arg" {
    const val = try decodeMany(struct { ?RecursiveOpt }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual(@as(?RecursiveOpt, null), val[0]);
}

// -- opt (parsing) --

test "construct: opt parsing null at opt empty" {
    try testing.expectEqual(@as(?void, null), try decode(?void, testing.allocator, comptime x("DIDL\\00\\01\\7f")));
}

test "construct: opt parsing null at opt empty 2" {
    try testing.expectEqual(@as(?Empty, null), try decode(?Empty, testing.allocator, comptime x("DIDL\\01\\6e\\6f\\01\\00\\00")));
}

test "construct: opt parsing null at opt bool" {
    try testing.expectEqual(@as(?bool, null), try decode(?bool, testing.allocator, comptime x("DIDL\\01\\6e\\7e\\01\\00\\00")));
}

test "construct: opt parsing opt false at opt bool" {
    try testing.expectEqual(@as(?bool, false), try decode(?bool, testing.allocator, comptime x("DIDL\\01\\6e\\7e\\01\\00\\01\\00")));
}

test "construct: opt parsing opt true at opt bool" {
    try testing.expectEqual(@as(?bool, true), try decode(?bool, testing.allocator, comptime x("DIDL\\01\\6e\\7e\\01\\00\\01\\01")));
}

test "construct: opt parsing invalid bool at opt bool" {
    try expectDecodeError(?bool, error.TypeMismatch, comptime x("DIDL\\01\\6e\\7e\\01\\00\\01\\02"));
}

test "construct: opt extra value" {
    const val = try decodeMany(struct { ?bool }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual(@as(?bool, null), val[0]);
}

// -- nested opt --

test "construct: opt parsing null at opt opt bool" {
    try testing.expectEqual(@as(??bool, null), try decode(??bool, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7e\\01\\00\\00")));
}

test "construct: opt parsing opt null at opt opt bool" {
    const val = try decode(??bool, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7e\\01\\00\\01\\00"));
    try testing.expectEqual(@as(?bool, null), val.?);
}

test "construct: opt parsing opt opt false at opt opt bool" {
    const val = try decode(??bool, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7e\\01\\00\\01\\01\\00"));
    try testing.expectEqual(@as(bool, false), val.?.?);
}

// -- opt subtype to constituent --

test "construct: opt parsing false at opt bool" {
    try testing.expectEqual(@as(?bool, false), try decode(?bool, testing.allocator, comptime x("DIDL\\00\\01\\7e\\00")));
}

test "construct: opt parsing true at opt bool" {
    try testing.expectEqual(@as(?bool, true), try decode(?bool, testing.allocator, comptime x("DIDL\\00\\01\\7e\\01")));
}

test "construct: opt parsing invalid bool at opt bool (subtype)" {
    try expectDecodeError(?bool, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e\\02"));
}

test "construct: opt null at opt opt null gives null" {
    try testing.expectEqual(@as(??void, null), try decode(??void, testing.allocator, comptime x("DIDL\\01\\6e\\7f\\01\\00\\00")));
}

test "construct: true at opt opt bool gives opt opt true" {
    const val = try decode(??bool, testing.allocator, comptime x("DIDL\\00\\01\\7e\\01"));
    try testing.expectEqual(@as(bool, true), val.?.?);
}

test "construct: true at recursive opt fails" {
    try expectDecodeError(?RecursiveOpt, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e\\01"));
}

test "construct: opt parsing null at Opt" {
    const val = try decode(?RecursiveOpt, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\00"));
    try testing.expectEqual(@as(?RecursiveOpt, null), val);
}

test "construct: opt parsing opt null at Opt" {
    const val = try decode(?RecursiveOpt, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\01\\00"));
    try testing.expect(val != null);
    try testing.expectEqual(@as(?RecursiveOpt, null), val.?.unwrap());
}

test "construct: opt parsing opt opt null at Opt" {
    const val = try decode(?RecursiveOpt, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\01\\01\\00"));
    defer if (val) |v| v.deinit(testing.allocator);
    try testing.expect(val != null);
    const inner = val.?.unwrap();
    try testing.expect(inner != null);
    try testing.expectEqual(@as(?RecursiveOpt, null), inner.?.unwrap());
}

test "construct: opt parsing opt opt opt null at Opt" {
    const val = try decode(?RecursiveOpt, testing.allocator, comptime x("DIDL\\01\\6e\\00\\01\\00\\01\\01\\01\\00"));
    defer if (val) |v| v.deinit(testing.allocator);
    try testing.expect(val != null);
}

test "construct: opt parsing fix record at fix record opt fails" {
    try expectDecodeError(?struct { void }, error.EndOfStream, comptime x("DIDL\\01\\6c\\01\\00\\00\\01\\00"));
}

// -- special opt subtyping --

test "construct: reserved <: opt nat" {
    try testing.expectEqual(@as(?u128, null), try decode(?u128, testing.allocator, comptime x("DIDL\\00\\01\\70")));
}

test "construct: null opt bool <: opt nat" {
    try testing.expectEqual(@as(?u128, null), try decode(?u128, testing.allocator, comptime x("DIDL\\01\\6e\\7e\\01\\00\\00")));
}

test "construct: opt true opt bool <: opt nat" {
    try testing.expectEqual(@as(?u128, null), try decode(?u128, testing.allocator, comptime x("DIDL\\01\\6e\\7e\\01\\00\\01\\01")));
}

test "construct: opt bool <: opt nat with invalid boolean value" {
    try expectDecodeError(?u128, error.TypeMismatch, comptime x("DIDL\\01\\6e\\7e\\01\\00\\01\\02"));
}

test "construct: opt opt true opt opt bool <: opt nat" {
    try testing.expectEqual(@as(?u128, null), try decode(?u128, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7e\\01\\00\\01\\01\\01")));
}

test "construct: opt opt true opt opt bool <: opt opt nat" {
    const val = try decode(??u128, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6e\\7e\\01\\00\\01\\01\\01"));
    try testing.expectEqual(@as(?u128, null), val.?);
}

test "construct: opt recovered coercion error under variant" {
    try testing.expectEqual(@as(?u128, null), try decode(?u128, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6b\\01\\00\\7e\\01\\00\\01\\00\\01")));
}

// -- special record field rules --

test "construct: missing optional record field" {
    const S = struct { foo: ?bool = null };
    const val = try decode(S, testing.allocator, comptime x("DIDL\\01\\6c\\00\\01\\00"));
    try testing.expectEqual(@as(?bool, null), val.foo);
}

test "construct: missing reserved record field" {
    const S = struct { foo: Reserved = .{} };
    const val = try decode(S, testing.allocator, comptime x("DIDL\\01\\6c\\00\\01\\00"));
    try testing.expectEqual(Reserved{}, val.foo);
}

// -- vec --

test "construct: vec int empty" {
    const val = try decode([]const i128, testing.allocator, comptime x("DIDL\\01\\6d\\7c\\01\\00\\00"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "construct: vec non subtype empty" {
    const val = try decode([]const i8, testing.allocator, comptime x("DIDL\\01\\6d\\7c\\01\\00\\00"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "construct: vec int two elements" {
    const val = try decode([]const i128, testing.allocator, comptime x("DIDL\\01\\6d\\7c\\01\\00\\02\\01\\02"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqual(@as(i128, 1), val[0]);
    try testing.expectEqual(@as(i128, 2), val[1]);
}

test "construct: vec nat8 as blob" {
    const val = try decode(Blob, testing.allocator, comptime x("DIDL\\01\\6d\\7b\\01\\00\\02\\01\\02"));
    defer testing.allocator.free(val.data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, val.data);
}

test "construct: vec null" {
    _ = try decode([]const void, testing.allocator, comptime x("DIDL\\01\\6d\\7f\\01\\00\\e8\\07"));
}

test "construct: vec null <: vec opt nat" {
    const val = try decode([]const ?u128, testing.allocator, comptime x("DIDL\\01\\6d\\7f\\01\\00\\e8\\07"));
    defer testing.allocator.free(val);
}

test "construct: vec int too short (missing count)" {
    try expectDecodeError([]const i128, error.EndOfStream, comptime x("DIDL\\01\\6d\\7c\\01\\00"));
}

test "construct: vec int too short (missing element)" {
    try expectDecodeError([]const i128, error.EndOfStream, comptime x("DIDL\\01\\6d\\7c\\01\\00\\02\\01"));
}

test "construct: vec int too long" {
    try expectDecodeError([]const i128, error.TrailingBytes, comptime x("DIDL\\01\\6d\\7c\\01\\00\\01\\01\\02"));
}

test "construct: vec recursive vector" {
    const val = try decode([]const []const ?Empty, testing.allocator, comptime x("DIDL\\01\\6d\\00\\01\\00\\00"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "construct: vec tree" {
    const val = try decode([]const []const ?Empty, testing.allocator, comptime x("DIDL\\01\\6d\\00\\01\\00\\02\\00\\00"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqual(@as(usize, 0), val[0].len);
    try testing.expectEqual(@as(usize, 0), val[1].len);
    testing.allocator.free(val[0]);
    testing.allocator.free(val[1]);
}

test "construct: vec non-recursive tree" {
    const val = try decode([]const []const ?Empty, testing.allocator, comptime x("DIDL\\01\\6d\\00\\01\\00\\02\\00\\00"));
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 2), val.len);
    testing.allocator.free(val[0]);
    testing.allocator.free(val[1]);
}

test "construct: vec of records" {
    _ = try decode([]const struct {}, testing.allocator, comptime x("DIDL\\02\\6d\\01\\6c\\00\\01\\00\\05"));
}

test "construct: vec of empty records" {
    const EmptyRecord = struct { @"0": ?*const @This() = null };
    try expectDecodeError([]const EmptyRecord, error.EndOfStream, comptime x("DIDL\\02\\6d\\01\\6c\\01\\00\\01\\01\\00\\01"));
}

// -- record --

test "construct: record empty" {
    _ = try decode(struct {}, testing.allocator, comptime x("DIDL\\01\\6c\\00\\01\\00"));
}

test "construct: record multiple" {
    _ = try decodeMany(struct { struct {}, struct {}, struct {} }, testing.allocator, comptime x("DIDL\\01\\6c\\00\\03\\00\\00\\00"));
}

test "construct: record {1: int} = 42" {
    const val = try decode(struct { ?void, i128 }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
    try testing.expectEqual(@as(i128, 42), val[1]);
}

test "construct: record {1: opt int} coercion" {
    const val = try decode(struct { ?void, ?i128 }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
    try testing.expectEqual(@as(i128, 42), val[1].?);
}

test "construct: record {1: reserved} coercion" {
    _ = try decode(struct { ?void, Reserved }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
}

test "construct: record ignore fields" {
    _ = try decode(struct {}, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
}

test "construct: record missing field" {
    try expectDecodeError(struct { ?void, ?void, i128 }, error.MissingField, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
}

test "construct: record missing opt field" {
    const val = try decode(struct { ?void, ?void, ?i128 }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7c\\01\\00\\2a"));
    try testing.expectEqual(@as(?i128, null), val[2]);
}

test "construct: record missing null field" {
    const val = try decode(struct { ?void, ?void, void }, testing.allocator, comptime x("DIDL\\01\\6c\\00\\01\\00"));
    try testing.expectEqual({}, val[2]);
}

test "construct: record tuple {int; bool}" {
    const val = try decode(struct { i128, bool }, testing.allocator, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\01\\00\\2a\\01"));
    try testing.expectEqual(@as(i128, 42), val[0]);
    try testing.expectEqual(true, val[1]);
}

test "construct: record ignore fields from tuple" {
    const val = try decode(struct { ?void, bool }, testing.allocator, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\01\\00\\2a\\01"));
    try testing.expectEqual(true, val[1]);
}

test "construct: record type mismatch in tuple" {
    try expectDecodeError(struct { bool, i128 }, error.TypeMismatch, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\01\\00\\2a\\01"));
}

test "construct: record duplicate fields" {
    try expectDecodeError(struct { i128, bool }, error.TypeMismatch, comptime x("DIDL\\01\\6c\\02\\00\\7c\\00\\7e\\01\\00\\2a\\01"));
}

test "construct: record unsorted" {
    try expectDecodeError(struct { ?void, i128, ?void, bool }, error.TypeMismatch, comptime x("DIDL\\01\\6c\\02\\01\\7c\\00\\7e\\01\\00\\2a\\01"));
}

test "construct: record named fields (foo, bar)" {
    const S = struct { foo: i128, bar: bool };
    const val = try decode(S, testing.allocator, comptime x("DIDL\\01\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\7c\\01\\00\\01\\2a"));
    try testing.expectEqual(true, val.bar);
    try testing.expectEqual(@as(i128, 42), val.foo);
}

test "construct: record field hash larger than u32" {
    try expectDecodeError(struct {}, error.Overflow, comptime x("DIDL\\01\\6c\\01\\80\\e4\\97\\d0\\12\\7c\\01\\00\\2a"));
}

test "construct: record nested" {
    const T = struct { struct { struct { struct {} } } };
    _ = try decode(T, testing.allocator, comptime x("DIDL\\04\\6c\\01\\00\\01\\6c\\01\\00\\02\\6c\\01\\00\\03\\6c\\00\\01\\00"));
}

test "construct: record value too short" {
    try expectDecodeError(struct { i128 }, error.EndOfStream, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\01\\00\\2a"));
}

test "construct: record value too long" {
    try expectDecodeError(struct { i128 }, error.TrailingBytes, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\01\\00\\2a\\01\\00"));
}

test "construct: record unicode field" {
    _ = try decode(struct {}, testing.allocator, comptime x("DIDL\\01\\6c\\01\\cd\\84\\b0\\05\\7f\\01\\00"));
}

test "construct: record empty recursion" {
    try expectDecodeError(struct { ?*const @This() }, error.EndOfStream, comptime x("DIDL\\01\\6c\\01\\00\\00\\01\\00"));
}

test "construct: record type too short 1" {
    try expectDecodeError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\01\\00\\2a\\01"));
}

test "construct: record type too short 2" {
    try expectDecodeError(struct {}, error.EndOfStream, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\00\\2a\\01"));
}

test "construct: record type too long" {
    try expectDecodeError(struct {}, error.TypeMismatch, comptime x("DIDL\\01\\6c\\02\\00\\7c\\01\\7e\\02\\7e\\01\\00\\2a\\01\\00"));
}

test "construct: record type out of range 1" {
    try expectDecodeError(struct {}, error.UnsupportedType, comptime x("DIDL\\01\\6c\\02\\00\\01\\01\\7e\\01\\00\\00\\00"));
}

test "construct: record type out of range 2" {
    try expectDecodeError(Reserved, error.UnsupportedType, comptime x("DIDL\\01\\6c\\02\\00\\01\\01\\7e\\01\\7c\\2a"));
}

test "construct: record missing data field greater" {
    const val = try decode(struct { ?void, void }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\00\\7d\\01\\00\\05"));
    try testing.expectEqual({}, val[1]);
}

test "construct: record missing data field less" {
    const val = try decode(struct { void, ?void }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\01\\7d\\01\\00\\05"));
    try testing.expectEqual({}, val[0]);
}

// -- variant --

test "construct: variant no empty value" {
    try expectDecodeError(void, error.TypeMismatch, comptime x("DIDL\\01\\6b\\00\\01\\00"));
}

test "construct: variant numbered field" {
    const V = union(enum) { @"0": void };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\00"));
    try testing.expectEqual(V.@"0", val);
}

test "construct: variant type mismatch in value" {
    try expectDecodeError(void, error.TypeMismatch, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\00\\2a"));
}

test "construct: variant ignore field" {
    const V = union(enum) { @"0": void, @"1": void };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\00"));
    try testing.expectEqual(V.@"0", val);
}

test "construct: variant change index" {
    const V = union(enum) { @"0": void, @"1": void, @"2": void };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7f\\01\\00\\01"));
    try testing.expectEqual(V.@"1", val);
}

test "construct: variant missing field" {
    try expectDecodeError(union(enum) { @"1": void }, error.UnknownVariant, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\00"));
}

test "construct: variant index out of range" {
    const V = union(enum) { a: void };
    try expectDecodeError(V, error.InvalidVariantIndex, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\01"));
}

test "construct: variant duplicate fields" {
    try expectDecodeError(union(enum) { a: void }, error.TypeMismatch, comptime x("DIDL\\01\\6b\\02\\00\\7f\\00\\7f\\01\\00\\00"));
}

test "construct: variant duplicate fields 2" {
    try expectDecodeError(union(enum) { a: void }, error.TypeMismatch, comptime x("DIDL\\01\\6b\\03\\00\\7f\\01\\7f\\01\\7f\\01\\00\\00"));
}

test "construct: variant unsorted" {
    try expectDecodeError(union(enum) { a: void, b: void }, error.TypeMismatch, comptime x("DIDL\\01\\6b\\02\\01\\7f\\00\\7f\\01\\00\\00"));
}

test "construct: variant enum Bar" {
    const V = union(enum) { Foo: void, Bar: void };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\b3\\d3\\c9\\01\\7f\\e6\\fd\\d5\\01\\7f\\01\\00\\00"));
    try testing.expectEqual(V.Bar, val);
}

test "construct: variant Foo/Bar/Baz" {
    const V = union(enum) {
        Foo: void,
        Bar: struct { bool, i128 },
        Baz: struct { a: i128, b: u128 },
    };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\03\\6b\\03\\b3\\d3\\c9\\01\\01\\bb\\d3\\c9\\01\\02\\e6\\fd\\d5\\01\\7f\\6c\\02\\00\\7e\\01\\7c\\6c\\02\\61\\7c\\62\\7d\\01\\00\\00\\01\\2a"));
    switch (val) {
        .Bar => |b| {
            try testing.expectEqual(true, b[0]);
            try testing.expectEqual(@as(i128, 42), b[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "construct: variant result Ok text" {
    const Result = union(enum) { Ok: []const u8, Err: []const u8 };
    const val = try decode(Result, testing.allocator, comptime x("DIDL\\01\\6b\\02\\bc\\8a\\01\\71\\c5\\fe\\d2\\01\\71\\01\\00\\00\\04good"));
    defer testing.allocator.free(val.Ok);
    try testing.expectEqualStrings("good", val.Ok);
}

test "construct: variant with empty" {
    const Result = union(enum) { ok: []const u8, err: Empty };
    const val = try decode(Result, testing.allocator, comptime x("DIDL\\02\\6b\\02\\9c\\c2\\01\\71\\e5\\8e\\b4\\02\\01\\6c\\01\\00\\01\\01\\00\\00\\04good"));
    defer testing.allocator.free(val.ok);
    try testing.expectEqualStrings("good", val.ok);
}

test "construct: variant with EmptyRecord" {
    const EmptyRecord = struct { @"0": ?*const @This() = null };
    const Result = union(enum) { ok: []const u8, err: EmptyRecord };
    const val = try decode(Result, testing.allocator, comptime x("DIDL\\02\\6b\\02\\9c\\c2\\01\\71\\e5\\8e\\b4\\02\\01\\6c\\01\\00\\01\\01\\00\\00\\04good"));
    defer testing.allocator.free(val.ok);
    try testing.expectEqualStrings("good", val.ok);
}

test "construct: variant value too short" {
    try expectDecodeError(union(enum) { @"0": void, @"1": i128 }, error.EndOfStream, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7c\\01\\00\\01"));
}

test "construct: variant value too long" {
    try expectDecodeError(union(enum) { @"0": void, @"1": i128 }, error.TrailingBytes, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7c\\01\\00\\01\\2a\\00"));
}

test "construct: variant type out of range" {
    try expectDecodeError(union(enum) { @"0": Reserved, @"1": i128 }, error.UnsupportedType, comptime x("DIDL\\01\\6b\\02\\00\\01\\01\\7c\\01\\00\\01\\2a"));
}

test "construct: variant type mismatch" {
    try expectDecodeError(union(enum) { @"0": void }, error.TrailingBytes, comptime x("DIDL\\01\\6b\\01\\00\\7f\\01\\00\\00\\2a"));
}

test "construct: variant type mismatch in unused tag" {
    const V = union(enum) { @"0": i128, @"1": i128 };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7c\\01\\00\\01\\2a"));
    try testing.expectEqual(@as(i128, 42), val.@"1");
}

test "construct: variant {0; 1:int} decode selected tag" {
    const V = union(enum) { @"0": void, @"1": i128 };
    const val = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7c\\01\\00\\01\\2a"));
    try testing.expectEqual(@as(i128, 42), val.@"1");
}

test "construct: variant {0;1} <: variant {0}" {
    const V = union(enum) { @"0": void };
    _ = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7f\\01\\00\\00"));
}

test "construct: variant {0;1} <: opt variant {0}" {
    const V = union(enum) { @"0": void };
    const val = try decode(?V, testing.allocator, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\7f\\01\\00\\00"));
    try testing.expect(val != null);
}

test "construct: variant ok with maxInt" {
    const V = union(enum) { @"0": void, @"1": void, @"4294967295": void };
    _ = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\03\\00\\7f\\01\\7f\\ff\\ff\\ff\\ff\\0f\\7f\\01\\00\\00"));
}

test "construct: variant unsorted with maxInt" {
    try expectDecodeError(
        union(enum) { @"0": void, @"1": void, @"4294967295": void },
        error.TypeMismatch,
        comptime x("DIDL\\01\\6b\\03\\00\\7f\\ff\\ff\\ff\\ff\\0f\\7f\\01\\7f\\01\\00\\00"),
    );
}

test "construct: variant unicode field" {
    _ = try decode(Reserved, testing.allocator, comptime x("DIDL\\01\\6b\\01\\cd\\84\\b0\\05\\7f\\01\\00\\00"));
}

test "construct: variant empty recursion" {
    try expectDecodeError(
        union(enum) { @"0": ?*const @This() },
        error.EndOfStream,
        comptime x("DIDL\\01\\6b\\01\\00\\00\\01\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00"),
    );
}

test "construct: variant field hash larger than u32" {
    try expectDecodeError(Reserved, error.Overflow, comptime x("DIDL\\01\\6b\\01\\80\\e4\\97\\d0\\12\\7c\\01\\00\\00\\2a"));
}

test "construct: variant type too short" {
    try expectDecodeError(union(enum) { @"0": void, @"1": void }, error.TypeMismatch, comptime x("DIDL\\01\\6b\\02\\00\\7f\\01\\00\\00"));
}

test "construct: variant type too long" {
    try expectDecodeError(union(enum) { @"0": void, @"1": void }, error.TypeMismatch, comptime x("DIDL\\01\\6b\\03\\00\\7f\\01\\7f\\01\\00\\00"));
}

// -- reserved vs null distinction --

test "construct: reserved" {
    _ = try decode(Reserved, testing.allocator, comptime x("DIDL\\00\\01\\70"));
}

test "construct: reserved not decodable as null" {
    try expectDecodeError(void, error.TypeMismatch, comptime x("DIDL\\00\\01\\70"));
}

test "construct: reserved reserved not null null" {
    try expectDecodeManyError(struct { void, void }, error.TypeMismatch, comptime x("DIDL\\00\\02\\70\\70"));
}

test "construct: reserved nat not null nat" {
    try expectDecodeManyError(struct { void, u128 }, error.TypeMismatch, comptime x("DIDL\\00\\02\\70\\7d\\05"));
}

test "construct: record with reserved field" {
    _ = try decode(struct { Reserved }, testing.allocator, comptime x("DIDL\\01\\6c\\01\\00\\70\\01\\00"));
}

test "construct: record with reserved field not null" {
    try expectDecodeError(struct { void }, error.TypeMismatch, comptime x("DIDL\\01\\6c\\01\\00\\70\\01\\00"));
}

test "construct: variant with reserved field" {
    const V = union(enum) { @"0": Reserved };
    _ = try decode(V, testing.allocator, comptime x("DIDL\\01\\6b\\01\\00\\70\\01\\00\\00"));
}

test "construct: variant with reserved field not null" {
    const V = union(enum) { @"0": void };
    try expectDecodeError(V, error.TypeMismatch, comptime x("DIDL\\01\\6b\\01\\00\\70\\01\\00\\00"));
}

test "construct: vector with reserved elements" {
    _ = try decode([]const Reserved, testing.allocator, comptime x("DIDL\\01\\6d\\70\\01\\00\\01"));
}

test "construct: vector with reserved not null" {
    try expectDecodeError([]const void, error.TypeMismatch, comptime x("DIDL\\01\\6d\\70\\01\\00\\01"));
}

test "construct: optional reserved element" {
    const val = try decode(?Reserved, testing.allocator, comptime x("DIDL\\01\\6e\\70\\01\\00\\01"));
    try testing.expect(val != null);
}

test "construct: optional reserved as optional null" {
    try testing.expectEqual(@as(?void, null), try decode(?void, testing.allocator, comptime x("DIDL\\01\\6e\\70\\01\\00\\01")));
}

// -- parsing other data as null --

test "construct: parsing nat as null fails" {
    try expectDecodeError(void, error.TypeMismatch, comptime x("DIDL\\00\\01\\7d\\05"));
}

// -- missing data --

test "construct: empty tuple into longer tuple" {
    const val = try decodeMany(struct { void }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual({}, val[0]);
}

test "construct: tuple into longer tuple" {
    const val = try decodeMany(struct { u128, u128, void }, testing.allocator, comptime x("DIDL\\00\\02\\7d\\7d\\05\\06"));
    try testing.expectEqual(@as(u128, 5), val[0]);
    try testing.expectEqual(@as(u128, 6), val[1]);
    try testing.expectEqual({}, val[2]);
}

// -- list (recursive record) --

test "construct: empty list" {
    const List = struct { head: i128, tail: ?*const @This() };
    const val = try decode(?*const List, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\00"));
    try testing.expectEqual(@as(?*const List, null), val);
}

test "construct: record list" {
    const List = struct { head: i128, tail: ?*const @This() };
    const val = try decode(?*const List, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\01\\01\\01\\02\\01\\03\\01\\04\\00"));
    try testing.expect(val != null);
    try testing.expectEqual(@as(i128, 1), val.?.head);
    try testing.expect(val.?.tail != null);
    try testing.expectEqual(@as(i128, 2), val.?.tail.?.head);
    defer {
        testing.allocator.destroy(val.?.tail.?.tail.?.tail.?);
        testing.allocator.destroy(val.?.tail.?.tail.?);
        testing.allocator.destroy(val.?.tail.?);
        testing.allocator.destroy(val.?);
    }
}

test "construct: record reorder type table" {
    const List = struct { head: i128, tail: ?*const @This() };
    const blob1 = comptime x("DIDL\\02\\6e\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\01\\01\\01\\02\\00");
    const blob2 = comptime x("DIDL\\02\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\01\\6e\\00\\01\\01\\01\\01\\01\\02\\00");
    const val1 = try decode(?*const List, testing.allocator, blob1);
    defer {
        testing.allocator.destroy(val1.?.tail.?);
        testing.allocator.destroy(val1.?);
    }
    const val2 = try decode(?*const List, testing.allocator, blob2);
    defer {
        testing.allocator.destroy(val2.?.tail.?);
        testing.allocator.destroy(val2.?);
    }
    try testing.expectEqual(@as(i128, 1), val1.?.head);
    try testing.expectEqual(@as(i128, 2), val1.?.tail.?.head);
    try testing.expectEqual(@as(?*const List, null), val1.?.tail.?.tail);
    try testing.expectEqual(val1.?.head, val2.?.head);
    try testing.expectEqual(val1.?.tail.?.head, val2.?.tail.?.head);
    try testing.expectEqual(val1.?.tail.?.tail, val2.?.tail.?.tail);
}

test "construct: record mutual recursive list" {
    const List = struct { head: i128, tail: ?*const @This() };
    const val = try decode(?*const List, testing.allocator, comptime x("DIDL\\02\\6e\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\01\\01\\01\\02\\00"));
    try testing.expect(val != null);
    try testing.expectEqual(@as(i128, 1), val.?.head);
    defer {
        testing.allocator.destroy(val.?.tail.?);
        testing.allocator.destroy(val.?);
    }
}

test "construct: variant empty list" {
    const VariantList = union(enum) { nil: void, cons: struct { head: i128, tail: ?*const @This() } };
    const val = try decode(VariantList, testing.allocator, comptime x("DIDL\\02\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\00"));
    try testing.expectEqual(VariantList.nil, val);
}

test "construct: variant list" {
    const VariantList = union(enum) {
        nil: void,
        cons: Cons,

        const Self = @This();
        const Cons = struct { head: i128, tail: ?*const Self = null };
    };
    const val = try decode(VariantList, testing.allocator, comptime x("DIDL\\02\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\01\\01\\01\\02\\00"));
    switch (val) {
        .cons => |c| {
            try testing.expectEqual(@as(i128, 1), c.head);
            try testing.expect(c.tail != null);
            switch (c.tail.?.*) {
                .cons => |c2| {
                    try testing.expectEqual(@as(i128, 2), c2.head);
                    if (c2.tail) |t| testing.allocator.destroy(t);
                    testing.allocator.destroy(c.tail.?);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "construct: variant extra args" {
    const VariantList = union(enum) { nil: void, cons: void };
    const val = try decodeMany(struct { VariantList, ?void, void, Reserved, ?i128 }, testing.allocator, comptime x("DIDL\\02\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\00"));
    try testing.expectEqual(VariantList.nil, val[0]);
}

test "construct: non-null extra args" {
    const VariantList = union(enum) { nil: void, cons: void };
    try expectDecodeManyError(struct { VariantList, ?i128, []const i128 }, error.TypeMismatch, comptime x("DIDL\\02\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\01\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\00\\01\\00\\00"));
}

// -- skip fields (A2 blob) --

test "construct: skip fields A1" {
    const A1 = struct { foo: i32, bar: bool };
    const val = try decode(A1, testing.allocator, comptime x("DIDL\\07\\6c\\07\\c3\\e3\\aa\\02\\01\\d3\\e3\\aa\\02\\7e\\d5\\e3\\aa\\02\\02\\db\\e3\\aa\\02\\01\\a2\\e5\\aa\\02\\04\\bb\\f1\\aa\\02\\06\\86\\8e\\b7\\02\\75\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\75\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\03\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\02\\6e\\05\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\04\\6b\\02\\d3\\e3\\aa\\02\\7f\\86\\8e\\b7\\02\\7f\\01\\00\\01\\0b\\00\\00\\00\\01\\00\\00\\0a\\00\\00\\00\\01\\14\\00\\00\\2a\\00\\00\\00"));
    try testing.expectEqual(@as(i32, 42), val.foo);
    try testing.expectEqual(true, val.bar);
}

test "construct: full A2 decode" {
    const ListNode = struct { head: i128, tail: ?*const @This() = null };
    const VL = union(enum) { nil: void, cons: struct { head: i128, tail: ?*const @This() = null } };
    const A1 = struct { foo: i32, bar: bool };
    const Bib = union(enum) { foo: void, bar: void };
    const A2 = struct {
        foo: i32,
        bar: bool,
        bat: VL,
        baz: A1,
        bbb: ?*const ListNode = null,
        bib: Bib,
        bab: A1,
    };
    const val = try decode(A2, testing.allocator, comptime x("DIDL\\07\\6c\\07\\c3\\e3\\aa\\02\\01\\d3\\e3\\aa\\02\\7e\\d5\\e3\\aa\\02\\02\\db\\e3\\aa\\02\\01\\a2\\e5\\aa\\02\\04\\bb\\f1\\aa\\02\\06\\86\\8e\\b7\\02\\75\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\75\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\03\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\02\\6e\\05\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\04\\6b\\02\\d3\\e3\\aa\\02\\7f\\86\\8e\\b7\\02\\7f\\01\\00\\01\\0b\\00\\00\\00\\01\\00\\00\\0a\\00\\00\\00\\01\\14\\00\\00\\2a\\00\\00\\00"));
    defer if (val.bbb) |node| testing.allocator.destroy(node);
    try testing.expectEqual(@as(i32, 42), val.foo);
    try testing.expectEqual(true, val.bar);
    try testing.expectEqual(VL.nil, val.bat);
    try testing.expectEqual(@as(i32, 10), val.baz.foo);
    try testing.expectEqual(false, val.baz.bar);
    try testing.expect(val.bbb != null);
    try testing.expectEqual(@as(i128, 20), val.bbb.?.head);
    try testing.expectEqual(Bib.bar, val.bib);
    try testing.expectEqual(@as(i32, 11), val.bab.foo);
    try testing.expectEqual(true, val.bab.bar);
}

test "construct: skip fields partial" {
    const ListNode = struct { head: i128, tail: ?*const @This() = null };
    const S = struct { bar: bool, baz: struct { bar: bool = false }, bbb: ?*const ListNode = null };
    const val = try decode(S, testing.allocator, comptime x("DIDL\\07\\6c\\07\\c3\\e3\\aa\\02\\01\\d3\\e3\\aa\\02\\7e\\d5\\e3\\aa\\02\\02\\db\\e3\\aa\\02\\01\\a2\\e5\\aa\\02\\04\\bb\\f1\\aa\\02\\06\\86\\8e\\b7\\02\\75\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\75\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\03\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\02\\6e\\05\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\04\\6b\\02\\d3\\e3\\aa\\02\\7f\\86\\8e\\b7\\02\\7f\\01\\00\\01\\0b\\00\\00\\00\\01\\00\\00\\0a\\00\\00\\00\\01\\14\\00\\00\\2a\\00\\00\\00"));
    defer if (val.bbb) |node| testing.allocator.destroy(node);
    try testing.expectEqual(true, val.bar);
    try testing.expectEqual(false, val.baz.bar);
    try testing.expect(val.bbb != null);
    try testing.expectEqual(@as(i128, 20), val.bbb.?.head);
}

test "construct: new record field fails" {
    const S = struct { foo: i32, new_field: bool };
    try expectDecodeError(S, error.MissingField, comptime x("DIDL\\07\\6c\\07\\c3\\e3\\aa\\02\\01\\d3\\e3\\aa\\02\\7e\\d5\\e3\\aa\\02\\02\\db\\e3\\aa\\02\\01\\a2\\e5\\aa\\02\\04\\bb\\f1\\aa\\02\\06\\86\\8e\\b7\\02\\75\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\75\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\03\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\02\\6e\\05\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\04\\6b\\02\\d3\\e3\\aa\\02\\7f\\86\\8e\\b7\\02\\7f\\01\\00\\01\\0b\\00\\00\\00\\01\\00\\00\\0a\\00\\00\\00\\01\\14\\00\\00\\2a\\00\\00\\00"));
}

test "construct: new variant field" {
    const VariantList = union(enum) {
        nil: void,
        cons: struct { head: i128, tail: ?*const @This() = null },
        new_field: Empty,
    };
    const S = struct { bat: VariantList };
    const val = try decode(S, testing.allocator, comptime x("DIDL\\07\\6c\\07\\c3\\e3\\aa\\02\\01\\d3\\e3\\aa\\02\\7e\\d5\\e3\\aa\\02\\02\\db\\e3\\aa\\02\\01\\a2\\e5\\aa\\02\\04\\bb\\f1\\aa\\02\\06\\86\\8e\\b7\\02\\75\\6c\\02\\d3\\e3\\aa\\02\\7e\\86\\8e\\b7\\02\\75\\6b\\02\\d1\\a7\\cf\\02\\7f\\f1\\f3\\92\\8e\\04\\03\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\02\\6e\\05\\6c\\02\\a0\\d2\\ac\\a8\\04\\7c\\90\\ed\\da\\e7\\04\\04\\6b\\02\\d3\\e3\\aa\\02\\7f\\86\\8e\\b7\\02\\7f\\01\\00\\01\\0b\\00\\00\\00\\01\\00\\00\\0a\\00\\00\\00\\01\\14\\00\\00\\2a\\00\\00\\00"));
    try testing.expectEqual(VariantList.nil, val.bat);
}

// -- future types --

test "construct: skipping minimal future type" {
    const val = try decodeMany(struct { ?Empty, bool }, testing.allocator, comptime x("DIDL\\01\\67\\00\\02\\00\\7e\\00\\00\\01"));
    try testing.expectEqual(@as(?Empty, null), val[0]);
    try testing.expectEqual(true, val[1]);
}

test "construct: skipping future type with data" {
    const val = try decodeMany(struct { ?Empty, bool }, testing.allocator, comptime x("DIDL\\01\\67\\03ABC\\02\\00\\7e\\05\\00hello\\01"));
    try testing.expectEqual(@as(?Empty, null), val[0]);
    try testing.expectEqual(true, val[1]);
}

test "construct: skipping future type with references" {
    // Future type value: m=0 data bytes, n=1 reference.
    // The reference is a bool (type -2 = 0x7e) with value 0x01.
    // If skipValue ignores n, the bool reference bytes remain unconsumed
    // and corrupt the next value (the actual bool arg).
    //
    // Type table: 1 entry, opcode 0x67 (-25), 0 type data bytes
    // Args: 2 - type 0 (future), type bool (0x7e)
    // Values: future(m=0, n=1, ref=bool(true)), bool(false)
    const val = try decodeMany(
        struct { ?Empty, bool },
        testing.allocator,
        comptime x("DIDL\\01\\67\\00\\02\\00\\7e\\00\\01\\7e\\01\\00"),
    );
    try testing.expectEqual(@as(?Empty, null), val[0]);
    try testing.expectEqual(false, val[1]);
}

// -- freeDecoded recursion --

test "construct: trailing bytes frees nested struct allocations" {
    // Encode a struct with a nested struct containing allocated text,
    // then append a trailing byte. freeDecoded must recurse into the
    // nested struct to free the text, otherwise testing.allocator will
    // report a leak.
    const Inner = struct { name: []const u8 };
    const Outer = struct { inner: Inner };
    const valid = try lib.encode(testing.allocator, .{Outer{ .inner = .{ .name = "hello" } }});
    defer testing.allocator.free(valid);

    const with_trail = try testing.allocator.alloc(u8, valid.len + 1);
    defer testing.allocator.free(with_trail);
    @memcpy(with_trail[0..valid.len], valid);
    with_trail[valid.len] = 0;

    try testing.expectError(error.TrailingBytes, decode(Outer, testing.allocator, with_trail));
}
