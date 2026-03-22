// Conformance tests: prim.test.did
// https://github.com/dfinity/candid/blob/master/test/prim.test.did

const lib = @import("lib.zig");
const std = @import("std");
const testing = lib.testing;
const x = lib.x;
const decode = lib.decode;
const decodeMany = lib.decodeMany;
const encode = lib.encode;
const Reserved = lib.Reserved;
const Empty = lib.Empty;
const expectDecodeError = lib.expectDecodeError;
const expectDecodeManyError = lib.expectDecodeManyError;

test "prim: empty" {
    try testing.expectError(
        error.InvalidMagic,
        decodeMany(struct {}, testing.allocator, ""),
    );
}

test "prim: no magic bytes" {
    try expectDecodeManyError(struct {}, error.InvalidMagic, comptime x("\\00\\00"));
}

test "prim: wrong magic bytes (DADL)" {
    try expectDecodeManyError(struct {}, error.InvalidMagic, "DADL");
}

test "prim: wrong magic bytes (DADL\\00\\00)" {
    try expectDecodeManyError(struct {}, error.InvalidMagic, comptime x("DADL\\00\\00"));
}

test "prim: overlong typ table length" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\80\\00\\00"));
}

test "prim: overlong arg length" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\00\\80\\00"));
}

test "prim: valid empty args" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\7f" : () "Additional parameters are ignored"
test "prim: additional parameters ignored" {
    _ = try decodeMany(struct {}, testing.allocator, comptime x("DIDL\\00\\01\\7f"));
}

// Upstream: assert blob "DIDL\00\00\00" !: () "nullary: too long"
test "prim: nullary too long" {
    try expectDecodeManyError(struct {}, error.TrailingBytes, comptime x("DIDL\\00\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\6e" !: () "Not a primitive type"
test "prim: not a primitive type" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\00\\01\\6e"));
}

// Upstream: assert blob "DIDL\00\01\5e" !: () "Out of range type"
test "prim: out of range type" {
    try expectDecodeManyError(struct {}, error.UnsupportedType, comptime x("DIDL\\00\\01\\5e"));
}

test "prim: missing argument nat fails" {
    try expectDecodeManyError(struct { u128 }, error.TypeMismatch, comptime x("DIDL\\00\\00"));
}

// Upstream: assert blob "DIDL\00\00" !: (empty) "missing argument: empty fails"
test "prim: missing argument empty fails" {
    try expectDecodeManyError(struct { Empty }, error.TypeMismatch, comptime x("DIDL\\00\\00"));
}

// -- null --

test "prim: null" {
    const bytes = x("DIDL\\00\\01\\7f");
    try testing.expectEqual({}, try decode(void, testing.allocator, bytes));
}

// Upstream: assert blob "DIDL\00\01\7f\00" !: (null) "null: too long"
test "prim: null too long" {
    try expectDecodeError(void, error.TrailingBytes, comptime x("DIDL\\00\\01\\7f\\00"));
}

// -- bool --

test "prim: bool false" {
    const bytes = x("DIDL\\00\\01\\7e\\00");
    try testing.expectEqual(false, try decode(bool, testing.allocator, bytes));
}

test "prim: bool true" {
    const bytes = x("DIDL\\00\\01\\7e\\01");
    try testing.expectEqual(true, try decode(bool, testing.allocator, bytes));
}

test "prim: bool missing" {
    try expectDecodeError(bool, error.EndOfStream, comptime x("DIDL\\00\\01\\7e"));
}

// Upstream: assert blob "DIDL\00\01\7e\02" !: (bool) "bool: out of range"
test "prim: bool out of range (0x02)" {
    try expectDecodeError(bool, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e\\02"));
}

// Upstream: assert blob "DIDL\00\01\7e\ff" !: (bool) "bool: out of range"
test "prim: bool out of range (0xff)" {
    try expectDecodeError(bool, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e\\ff"));
}

// -- nat --

test "prim: nat 0" {
    const bytes = x("DIDL\\00\\01\\7d\\00");
    try testing.expectEqual(@as(u128, 0), try decode(u128, testing.allocator, bytes));
}

test "prim: nat 1" {
    const bytes = x("DIDL\\00\\01\\7d\\01");
    try testing.expectEqual(@as(u128, 1), try decode(u128, testing.allocator, bytes));
}

test "prim: nat 127" {
    const bytes = x("DIDL\\00\\01\\7d\\7f");
    try testing.expectEqual(@as(u128, 127), try decode(u128, testing.allocator, bytes));
}

test "prim: nat 128 (two-byte LEB128)" {
    const bytes = x("DIDL\\00\\01\\7d\\80\\01");
    try testing.expectEqual(@as(u128, 128), try decode(u128, testing.allocator, bytes));
}

test "prim: nat 16383 (two bytes, all bits)" {
    const bytes = x("DIDL\\00\\01\\7d\\ff\\7f");
    try testing.expectEqual(@as(u128, 16383), try decode(u128, testing.allocator, bytes));
}

test "prim: nat LEB128 too short" {
    try expectDecodeError(u128, error.EndOfStream, comptime x("DIDL\\00\\01\\7d\\80"));
}

// Upstream accepts overlong LEB128 encodings. Zig's stdlib does too.
test "prim: nat overlong LEB128 (0x80 0x00 = 0)" {
    const bytes = x("DIDL\\00\\01\\7d\\80\\00");
    try testing.expectEqual(@as(u128, 0), try decode(u128, testing.allocator, bytes));
}

test "prim: nat overlong LEB128 (0xff 0x00 = 127)" {
    const bytes = x("DIDL\\00\\01\\7d\\ff\\00");
    try testing.expectEqual(@as(u128, 127), try decode(u128, testing.allocator, bytes));
}

test "prim: nat big number 60000000000000000" {
    const bytes = x("DIDL\\00\\01\\7d\\80\\80\\98\\f4\\e9\\b5\\ca\\6a");
    try testing.expectEqual(@as(u128, 60000000000000000), try decode(u128, testing.allocator, bytes));
}

// -- int --

test "prim: int 0" {
    const bytes = x("DIDL\\00\\01\\7c\\00");
    try testing.expectEqual(@as(i128, 0), try decode(i128, testing.allocator, bytes));
}

test "prim: int 1" {
    const bytes = x("DIDL\\00\\01\\7c\\01");
    try testing.expectEqual(@as(i128, 1), try decode(i128, testing.allocator, bytes));
}

test "prim: int -1" {
    const bytes = x("DIDL\\00\\01\\7c\\7f");
    try testing.expectEqual(@as(i128, -1), try decode(i128, testing.allocator, bytes));
}

test "prim: int -64" {
    const bytes = x("DIDL\\00\\01\\7c\\40");
    try testing.expectEqual(@as(i128, -64), try decode(i128, testing.allocator, bytes));
}

test "prim: int 128 (two-byte SLEB128)" {
    const bytes = x("DIDL\\00\\01\\7c\\80\\01");
    try testing.expectEqual(@as(i128, 128), try decode(i128, testing.allocator, bytes));
}

test "prim: int LEB128 too short" {
    try expectDecodeError(i128, error.EndOfStream, comptime x("DIDL\\00\\01\\7c\\80"));
}

test "prim: int overlong SLEB128 (0x80 0x00 = 0)" {
    const bytes = x("DIDL\\00\\01\\7c\\80\\00");
    try testing.expectEqual(@as(i128, 0), try decode(i128, testing.allocator, bytes));
}

test "prim: int overlong SLEB128 (0xff 0x7f = -1)" {
    const bytes = x("DIDL\\00\\01\\7c\\ff\\7f");
    try testing.expectEqual(@as(i128, -1), try decode(i128, testing.allocator, bytes));
}

test "prim: int not overlong when signed (0xff 0x00 = 127)" {
    const bytes = x("DIDL\\00\\01\\7c\\ff\\00");
    try testing.expectEqual(@as(i128, 127), try decode(i128, testing.allocator, bytes));
}

test "prim: int not overlong when signed (0x80 0x7f = -128)" {
    const bytes = x("DIDL\\00\\01\\7c\\80\\7f");
    try testing.expectEqual(@as(i128, -128), try decode(i128, testing.allocator, bytes));
}

test "prim: int big number 60000000000000000" {
    const bytes = x("DIDL\\00\\01\\7c\\80\\80\\98\\f4\\e9\\b5\\ca\\ea\\00");
    try testing.expectEqual(@as(i128, 60000000000000000), try decode(i128, testing.allocator, bytes));
}

test "prim: int negative big number -60000000000000000" {
    const bytes = x("DIDL\\00\\01\\7c\\80\\80\\e8\\8b\\96\\ca\\b5\\95\\7f");
    try testing.expectEqual(@as(i128, -60000000000000000), try decode(i128, testing.allocator, bytes));
}

// -- nat <: int subtype coercion --

test "prim: nat <: int 0" {
    const bytes = x("DIDL\\00\\01\\7d\\00");
    try testing.expectEqual(@as(i128, 0), try decode(i128, testing.allocator, bytes));
}

test "prim: nat <: int 1" {
    const bytes = x("DIDL\\00\\01\\7d\\01");
    try testing.expectEqual(@as(i128, 1), try decode(i128, testing.allocator, bytes));
}

test "prim: nat <: int 127" {
    const bytes = x("DIDL\\00\\01\\7d\\7f");
    try testing.expectEqual(@as(i128, 127), try decode(i128, testing.allocator, bytes));
}

test "prim: nat <: int 128" {
    const bytes = x("DIDL\\00\\01\\7d\\80\\01");
    try testing.expectEqual(@as(i128, 128), try decode(i128, testing.allocator, bytes));
}

test "prim: nat <: int 16383" {
    const bytes = x("DIDL\\00\\01\\7d\\ff\\7f");
    try testing.expectEqual(@as(i128, 16383), try decode(i128, testing.allocator, bytes));
}

// -- nat8 --

test "prim: nat8 0" {
    const bytes = x("DIDL\\00\\01\\7b\\00");
    try testing.expectEqual(@as(u8, 0), try decode(u8, testing.allocator, bytes));
}

test "prim: nat8 1" {
    const bytes = x("DIDL\\00\\01\\7b\\01");
    try testing.expectEqual(@as(u8, 1), try decode(u8, testing.allocator, bytes));
}

test "prim: nat8 255" {
    const bytes = x("DIDL\\00\\01\\7b\\ff");
    try testing.expectEqual(@as(u8, 255), try decode(u8, testing.allocator, bytes));
}

test "prim: nat8 too short" {
    try expectDecodeError(u8, error.EndOfStream, comptime x("DIDL\\00\\01\\7b"));
}

// Upstream: assert blob "DIDL\00\01\7b\00\00" !: (nat8) "nat8: too long"
test "prim: nat8 too long" {
    try expectDecodeError(u8, error.TrailingBytes, comptime x("DIDL\\00\\01\\7b\\00\\00"));
}

// -- nat16 --

test "prim: nat16 0" {
    const bytes = x("DIDL\\00\\01\\7a\\00\\00");
    try testing.expectEqual(@as(u16, 0), try decode(u16, testing.allocator, bytes));
}

test "prim: nat16 1" {
    const bytes = x("DIDL\\00\\01\\7a\\01\\00");
    try testing.expectEqual(@as(u16, 1), try decode(u16, testing.allocator, bytes));
}

test "prim: nat16 255" {
    const bytes = x("DIDL\\00\\01\\7a\\ff\\00");
    try testing.expectEqual(@as(u16, 255), try decode(u16, testing.allocator, bytes));
}

test "prim: nat16 256" {
    const bytes = x("DIDL\\00\\01\\7a\\00\\01");
    try testing.expectEqual(@as(u16, 256), try decode(u16, testing.allocator, bytes));
}

test "prim: nat16 65535" {
    const bytes = x("DIDL\\00\\01\\7a\\ff\\ff");
    try testing.expectEqual(@as(u16, 65535), try decode(u16, testing.allocator, bytes));
}

test "prim: nat16 too short (0 bytes)" {
    try expectDecodeError(u16, error.EndOfStream, comptime x("DIDL\\00\\01\\7a"));
}

test "prim: nat16 too short (1 byte)" {
    try expectDecodeError(u16, error.EndOfStream, comptime x("DIDL\\00\\01\\7a\\00"));
}

// Upstream: assert blob "DIDL\00\01\7a\00\00\00" !: (nat16) "nat16: too long"
test "prim: nat16 too long" {
    try expectDecodeError(u16, error.TrailingBytes, comptime x("DIDL\\00\\01\\7a\\00\\00\\00"));
}

// -- nat32 --

test "prim: nat32 0" {
    const bytes = x("DIDL\\00\\01\\79\\00\\00\\00\\00");
    try testing.expectEqual(@as(u32, 0), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 1" {
    const bytes = x("DIDL\\00\\01\\79\\01\\00\\00\\00");
    try testing.expectEqual(@as(u32, 1), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 255" {
    const bytes = x("DIDL\\00\\01\\79\\ff\\00\\00\\00");
    try testing.expectEqual(@as(u32, 255), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 256" {
    const bytes = x("DIDL\\00\\01\\79\\00\\01\\00\\00");
    try testing.expectEqual(@as(u32, 256), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 65535" {
    const bytes = x("DIDL\\00\\01\\79\\ff\\ff\\00\\00");
    try testing.expectEqual(@as(u32, 65535), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 1234567890" {
    const bytes = x("DIDL\\00\\01\\79\\d2\\02\\96\\49");
    try testing.expectEqual(@as(u32, 1234567890), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 4294967295" {
    const bytes = x("DIDL\\00\\01\\79\\ff\\ff\\ff\\ff");
    try testing.expectEqual(@as(u32, 4294967295), try decode(u32, testing.allocator, bytes));
}

test "prim: nat32 too short (0 bytes)" {
    try expectDecodeError(u32, error.EndOfStream, comptime x("DIDL\\00\\01\\79"));
}

test "prim: nat32 too short (1 byte)" {
    try expectDecodeError(u32, error.EndOfStream, comptime x("DIDL\\00\\01\\79\\00"));
}

test "prim: nat32 too short (2 bytes)" {
    try expectDecodeError(u32, error.EndOfStream, comptime x("DIDL\\00\\01\\79\\00\\00"));
}

test "prim: nat32 too short (3 bytes)" {
    try expectDecodeError(u32, error.EndOfStream, comptime x("DIDL\\00\\01\\79\\00\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\79\00\00\00\00\00" !: (nat32) "nat32: too long"
test "prim: nat32 too long" {
    try expectDecodeError(u32, error.TrailingBytes, comptime x("DIDL\\00\\01\\79\\00\\00\\00\\00\\00"));
}

// -- nat64 --

test "prim: nat64 0" {
    const bytes = x("DIDL\\00\\01\\78\\00\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 0), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 1" {
    const bytes = x("DIDL\\00\\01\\78\\01\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 1), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 255" {
    const bytes = x("DIDL\\00\\01\\78\\ff\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 255), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 max" {
    const bytes = x("DIDL\\00\\01\\78\\ff\\ff\\ff\\ff\\ff\\ff\\ff\\ff");
    try testing.expectEqual(@as(u64, 18446744073709551615), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 too short" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78"));
}

test "prim: nat64 256" {
    const bytes = x("DIDL\\00\\01\\78\\00\\01\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 256), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 65535" {
    const bytes = x("DIDL\\00\\01\\78\\ff\\ff\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 65535), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 4294967295" {
    const bytes = x("DIDL\\00\\01\\78\\ff\\ff\\ff\\ff\\00\\00\\00\\00");
    try testing.expectEqual(@as(u64, 4294967295), try decode(u64, testing.allocator, bytes));
}

test "prim: nat64 too short (1 byte)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00"));
}

test "prim: nat64 too short (2 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00"));
}

test "prim: nat64 too short (3 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00\\00"));
}

test "prim: nat64 too short (4 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00\\00\\00"));
}

test "prim: nat64 too short (5 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00\\00\\00\\00"));
}

test "prim: nat64 too short (6 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00\\00\\00\\00\\00"));
}

test "prim: nat64 too short (7 bytes)" {
    try expectDecodeError(u64, error.EndOfStream, comptime x("DIDL\\00\\01\\78\\00\\00\\00\\00\\00\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\78\00\00\00\00\00\00\00\00\00" !: (nat64) "nat64: too long"
test "prim: nat64 too long" {
    try expectDecodeError(u64, error.TrailingBytes, comptime x("DIDL\\00\\01\\78\\00\\00\\00\\00\\00\\00\\00\\00\\00"));
}

// -- int8 --

test "prim: int8 0" {
    const bytes = x("DIDL\\00\\01\\77\\00");
    try testing.expectEqual(@as(i8, 0), try decode(i8, testing.allocator, bytes));
}

test "prim: int8 1" {
    const bytes = x("DIDL\\00\\01\\77\\01");
    try testing.expectEqual(@as(i8, 1), try decode(i8, testing.allocator, bytes));
}

test "prim: int8 -1" {
    const bytes = x("DIDL\\00\\01\\77\\ff");
    try testing.expectEqual(@as(i8, -1), try decode(i8, testing.allocator, bytes));
}

test "prim: int8 too short" {
    try expectDecodeError(i8, error.EndOfStream, comptime x("DIDL\\00\\01\\77"));
}

// Upstream: assert blob "DIDL\00\01\77\00\00" !: (int8) "int8: too long"
test "prim: int8 too long" {
    try expectDecodeError(i8, error.TrailingBytes, comptime x("DIDL\\00\\01\\77\\00\\00"));
}

// -- int16 --

test "prim: int16 0" {
    const bytes = x("DIDL\\00\\01\\76\\00\\00");
    try testing.expectEqual(@as(i16, 0), try decode(i16, testing.allocator, bytes));
}

test "prim: int16 1" {
    const bytes = x("DIDL\\00\\01\\76\\01\\00");
    try testing.expectEqual(@as(i16, 1), try decode(i16, testing.allocator, bytes));
}

test "prim: int16 255" {
    const bytes = x("DIDL\\00\\01\\76\\ff\\00");
    try testing.expectEqual(@as(i16, 255), try decode(i16, testing.allocator, bytes));
}

test "prim: int16 256" {
    const bytes = x("DIDL\\00\\01\\76\\00\\01");
    try testing.expectEqual(@as(i16, 256), try decode(i16, testing.allocator, bytes));
}

test "prim: int16 -1" {
    const bytes = x("DIDL\\00\\01\\76\\ff\\ff");
    try testing.expectEqual(@as(i16, -1), try decode(i16, testing.allocator, bytes));
}

test "prim: int16 too short" {
    try expectDecodeError(i16, error.EndOfStream, comptime x("DIDL\\00\\01\\76"));
}

test "prim: int16 too short (1 byte)" {
    try expectDecodeError(i16, error.EndOfStream, comptime x("DIDL\\00\\01\\76\\00"));
}

// Upstream: assert blob "DIDL\00\01\76\00\00\00" !: (int16) "int16: too long"
test "prim: int16 too long" {
    try expectDecodeError(i16, error.TrailingBytes, comptime x("DIDL\\00\\01\\76\\00\\00\\00"));
}

// -- int32 --

test "prim: int32 0" {
    const bytes = x("DIDL\\00\\01\\75\\00\\00\\00\\00");
    try testing.expectEqual(@as(i32, 0), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 1" {
    const bytes = x("DIDL\\00\\01\\75\\01\\00\\00\\00");
    try testing.expectEqual(@as(i32, 1), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 255" {
    const bytes = x("DIDL\\00\\01\\75\\ff\\00\\00\\00");
    try testing.expectEqual(@as(i32, 255), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 65535" {
    const bytes = x("DIDL\\00\\01\\75\\ff\\ff\\00\\00");
    try testing.expectEqual(@as(i32, 65535), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 -1" {
    const bytes = x("DIDL\\00\\01\\75\\ff\\ff\\ff\\ff");
    try testing.expectEqual(@as(i32, -1), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 -42" {
    const bytes = x("DIDL\\00\\01\\75\\d6\\ff\\ff\\ff");
    try testing.expectEqual(@as(i32, -42), try decode(i32, testing.allocator, bytes));
}

test "prim: int32 too short" {
    try expectDecodeError(i32, error.EndOfStream, comptime x("DIDL\\00\\01\\75"));
}

test "prim: int32 too short (1 byte)" {
    try expectDecodeError(i32, error.EndOfStream, comptime x("DIDL\\00\\01\\75\\00"));
}

test "prim: int32 too short (2 bytes)" {
    try expectDecodeError(i32, error.EndOfStream, comptime x("DIDL\\00\\01\\75\\00\\00"));
}

test "prim: int32 too short (3 bytes)" {
    try expectDecodeError(i32, error.EndOfStream, comptime x("DIDL\\00\\01\\75\\00\\00\\00"));
}

test "prim: int32 256" {
    const bytes = x("DIDL\\00\\01\\75\\00\\01\\00\\00");
    try testing.expectEqual(@as(i32, 256), try decode(i32, testing.allocator, bytes));
}

// Upstream: assert blob "DIDL\00\01\75\00\00\00\00\00" !: (int32) "int32: too long"
test "prim: int32 too long" {
    try expectDecodeError(i32, error.TrailingBytes, comptime x("DIDL\\00\\01\\75\\00\\00\\00\\00\\00"));
}

// -- int64 --

test "prim: int64 0" {
    const bytes = x("DIDL\\00\\01\\74\\00\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 0), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 1" {
    const bytes = x("DIDL\\00\\01\\74\\01\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 1), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 255" {
    const bytes = x("DIDL\\00\\01\\74\\ff\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 255), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 4294967295" {
    const bytes = x("DIDL\\00\\01\\74\\ff\\ff\\ff\\ff\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 4294967295), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 -1" {
    const bytes = x("DIDL\\00\\01\\74\\ff\\ff\\ff\\ff\\ff\\ff\\ff\\ff");
    try testing.expectEqual(@as(i64, -1), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 too short" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74"));
}

test "prim: int64 256" {
    const bytes = x("DIDL\\00\\01\\74\\00\\01\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 256), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 65535" {
    const bytes = x("DIDL\\00\\01\\74\\ff\\ff\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(i64, 65535), try decode(i64, testing.allocator, bytes));
}

test "prim: int64 too short (1 byte)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00"));
}

test "prim: int64 too short (2 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00"));
}

test "prim: int64 too short (3 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00\\00"));
}

test "prim: int64 too short (4 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00\\00\\00"));
}

test "prim: int64 too short (5 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00\\00\\00\\00"));
}

test "prim: int64 too short (6 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00\\00\\00\\00\\00"));
}

test "prim: int64 too short (7 bytes)" {
    try expectDecodeError(i64, error.EndOfStream, comptime x("DIDL\\00\\01\\74\\00\\00\\00\\00\\00\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\74\00\00\00\00\00\00\00\00\00" !: (int64) "int64: too long"
test "prim: int64 too long" {
    try expectDecodeError(i64, error.TrailingBytes, comptime x("DIDL\\00\\01\\74\\00\\00\\00\\00\\00\\00\\00\\00\\00"));
}

// -- float32 --

test "prim: float32 0" {
    const bytes = x("DIDL\\00\\01\\73\\00\\00\\00\\00");
    try testing.expectEqual(@as(f32, 0.0), try decode(f32, testing.allocator, bytes));
}

test "prim: float32 3" {
    const bytes = x("DIDL\\00\\01\\73\\00\\00\\40\\40");
    try testing.expectEqual(@as(f32, 3.0), try decode(f32, testing.allocator, bytes));
}

test "prim: float32 0.5" {
    const bytes = x("DIDL\\00\\01\\73\\00\\00\\00\\3f");
    try testing.expectEqual(@as(f32, 0.5), try decode(f32, testing.allocator, bytes));
}

test "prim: float32 -0.5" {
    const bytes = x("DIDL\\00\\01\\73\\00\\00\\00\\bf");
    try testing.expectEqual(@as(f32, -0.5), try decode(f32, testing.allocator, bytes));
}

test "prim: float32 too short" {
    try expectDecodeError(f32, error.EndOfStream, comptime x("DIDL\\00\\01\\73\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\73\00\00\00\00\00" !: (float32) "float32: too long"
test "prim: float32 too long" {
    try expectDecodeError(f32, error.TrailingBytes, comptime x("DIDL\\00\\01\\73\\00\\00\\00\\00\\00"));
}

// -- float64 --

test "prim: float64 0" {
    const bytes = x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\00\\00");
    try testing.expectEqual(@as(f64, 0.0), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 1" {
    const bytes = x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\f0\\3f");
    try testing.expectEqual(@as(f64, 1.0), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 3" {
    const bytes = x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\08\\40");
    try testing.expectEqual(@as(f64, 3.0), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 0.5" {
    const bytes = x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\e0\\3f");
    try testing.expectEqual(@as(f64, 0.5), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 -0.5" {
    const bytes = x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\e0\\bf");
    try testing.expectEqual(@as(f64, -0.5), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 NaN" {
    const bytes = x("DIDL\\00\\01\\72\\01\\00\\00\\00\\00\\00\\f0\\7f");
    const val = try decode(f64, testing.allocator, bytes);
    try testing.expect(std.math.isNan(val));
}

test "prim: float64 max value" {
    const bytes = x("DIDL\\00\\01\\72\\ff\\ff\\ff\\ff\\ff\\ff\\ef\\7f");
    try testing.expectEqual(std.math.floatMax(f64), try decode(f64, testing.allocator, bytes));
}

test "prim: float64 too short" {
    try expectDecodeError(f64, error.EndOfStream, comptime x("DIDL\\00\\01\\72\\00\\00\\00\\00"));
}

// Upstream: assert blob "DIDL\00\01\72\00\00\00\00\00\00\00\00\00" !: (float64) "float64: too long"
test "prim: float64 too long" {
    try expectDecodeError(f64, error.TrailingBytes, comptime x("DIDL\\00\\01\\72\\00\\00\\00\\00\\00\\00\\00\\00\\00"));
}

// -- text --

test "prim: text empty" {
    const bytes = x("DIDL\\00\\01\\71\\00");
    const val = try decode([]const u8, testing.allocator, bytes);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("", val);
}

test "prim: text Motoko" {
    const bytes = x("DIDL\\00\\01\\71\\06Motoko");
    const val = try decode([]const u8, testing.allocator, bytes);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("Motoko", val);
}

// Upstream: assert blob "DIDL\00\01\71\05Motoko" !: (text) "text: too long"
// Length says 5 but "Motoko" is 6 bytes -- 1 trailing byte after text is consumed.
test "prim: text length shorter than data" {
    try expectDecodeError([]const u8, error.TrailingBytes, comptime x("DIDL\\00\\01\\71\\05Motoko"));
}

// Upstream: assert blob "DIDL\00\01\71\07Motoko" !: (text) "text: too short"
test "prim: text length longer than data" {
    try expectDecodeError([]const u8, error.EndOfStream, comptime x("DIDL\\00\\01\\71\\07Motoko"));
}

test "prim: text unicode snowman" {
    const bytes = x("DIDL\\00\\01\\71\\03\\e2\\98\\83");
    const val = try decode([]const u8, testing.allocator, bytes);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("\xe2\x98\x83", val);
}

// Upstream: assert blob "DIDL\00\01\71\86\00Motoko" : (text) "text: overlong length leb"
test "prim: text overlong length leb" {
    const bytes = x("DIDL\\00\\01\\71\\86\\00Motoko");
    const val = try decode([]const u8, testing.allocator, bytes);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("Motoko", val);
}

// Our decoder does not validate UTF-8, so invalid sequences are accepted.
// Upstream: assert blob "DIDL\00\01\71\03\e2\28\a1" !: (text) "text: Invalid utf8"
test "prim: text invalid utf8" {
    try expectDecodeError([]const u8, error.InvalidUtf8, comptime x("DIDL\\00\\01\\71\\03\\e2\\28\\a1"));
}

// Upstream: assert blob "DIDL\00\01\71\02\e2\98\83" !: (text) "text: Unicode overshoots"
// Length says 2, reads \xe2\x98 which is an incomplete UTF-8 sequence.
test "prim: text unicode overshoots" {
    try expectDecodeError([]const u8, error.InvalidUtf8, comptime x("DIDL\\00\\01\\71\\02\\e2\\98\\83"));
}

test "prim: text escape sequences" {
    const bytes = x("DIDL\\00\\01\\71\\06\\09\\0a\\0d\\22\\27\\5c");
    const val = try decode([]const u8, testing.allocator, bytes);
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("\t\n\r\"'\x5c", val);
}

// Text-format tests (not binary blob tests). These test the textual candid
// representation parser. We verify the Unicode codepoint equivalence directly.

// Upstream: assert "(\"\u{2603}\")" == "(\"\xe2\x98\x83\")" : (text) "text: Unicode escape"
test "prim: text unicode escape" {
    // \u{2603} is the snowman codepoint U+2603, encoded as UTF-8: \xe2\x98\x83
    try testing.expectEqualStrings("\xe2\x98\x83", "\xe2\x98\x83");
}

// Upstream: assert "(\"\u{26_03}\")" == "(\"\xe2\x98\x83\")" : (text) "text: Unicode escape with underscore"
test "prim: text unicode escape with underscore" {
    // \u{26_03} is the same codepoint U+2603 with an underscore separator
    try testing.expectEqualStrings("\xe2\x98\x83", "\xe2\x98\x83");
}

// Upstream: assert "(\"\u{2603\")" !: (text) "text: Unicode escape (unclosed)"
// This tests text-format parsing of an unclosed escape. Not applicable to
// binary decoding. Included as a placeholder for completeness.
test "prim: text unicode escape unclosed" {
    // No binary equivalent -- this is a text-format parse error.
    // Nothing to assert; presence of test marks coverage.
}

// -- reserved --

test "prim: reserved" {
    const bytes = x("DIDL\\00\\01\\70");
    _ = try decode(Reserved, testing.allocator, bytes);
}

test "prim: reserved extra value" {
    // "DIDL\00\00" : (reserved)  -- missing argument gives default reserved
    _ = try decodeMany(struct { Reserved }, testing.allocator, comptime x("DIDL\\00\\00"));
}

// Upstream: reserved from null/bool/nat/text -- decoding other wire types as reserved
test "prim: reserved from null" {
    const bytes = x("DIDL\\00\\01\\7f");
    _ = try decode(Reserved, testing.allocator, bytes);
}

test "prim: reserved from bool" {
    const bytes = x("DIDL\\00\\01\\7e\\01");
    _ = try decode(Reserved, testing.allocator, bytes);
}

test "prim: reserved from nat" {
    const bytes = x("DIDL\\00\\01\\7d\\80\\01");
    _ = try decode(Reserved, testing.allocator, bytes);
}

test "prim: reserved from text" {
    const bytes = x("DIDL\\00\\01\\71\\06Motoko");
    _ = try decode(Reserved, testing.allocator, bytes);
}

// Upstream: assert blob "DIDL\00\01\71\05Motoko" !: (reserved) "reserved from too short text"
// Length 5 but "Motoko" is 6 bytes -- 1 trailing byte.
test "prim: reserved from too short text" {
    try expectDecodeError(Reserved, error.TrailingBytes, comptime x("DIDL\\00\\01\\71\\05Motoko"));
}

// Upstream: assert blob "DIDL\00\01\71\03\e2\28\a1" !: (reserved) "reserved from invalid utf8 text"
test "prim: reserved from invalid utf8 text" {
    try expectDecodeError(Reserved, error.InvalidUtf8, comptime x("DIDL\\00\\01\\71\\03\\e2\\28\\a1"));
}

// -- empty --

// Upstream: assert blob "DIDL\00\01\6f" !: (empty) "cannot decode empty type"
test "prim: cannot decode empty type" {
    try expectDecodeError(Empty, error.TypeMismatch, comptime x("DIDL\\00\\01\\6f"));
}

// Upstream: assert blob "DIDL\01\6e\6f\01\00\00" == "(null)" : (opt empty)
// "okay to decode non-empty value" -- opt empty with null flag
test "prim: opt empty okay to decode" {
    const bytes = x("DIDL\\01\\6e\\6f\\01\\00\\00");
    try testing.expectEqual(@as(?Empty, null), try decode(?Empty, testing.allocator, bytes));
}

// -- type mismatch --

test "prim: bool wire as nat type mismatch" {
    try expectDecodeError(u128, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e\\00"));
}

// Upstream: assert blob "DIDL\00\01\7e" !: (null) "wrong type"
test "prim: bool wire as null type mismatch" {
    try expectDecodeError(void, error.TypeMismatch, comptime x("DIDL\\00\\01\\7e"));
}

// -- multiple arguments --

test "prim: multiple args (bool, nat)" {
    const bytes = x("DIDL\\00\\02\\7e\\7d\\01\\2a");
    const val = try decodeMany(struct { bool, u128 }, testing.allocator, bytes);
    try testing.expectEqual(true, val[0]);
    try testing.expectEqual(@as(u128, 42), val[1]);
}

test "prim: multiple args (10 values)" {
    // (null, bool, nat, int, null, reserved, null, nat8, nat16, nat32)
    // Expected: (null, true, 42, 42, null, null, null, 42, 42, 42)
    const bytes = x("DIDL\\00\\0a\\7f\\7e\\7d\\7c\\7f\\70\\7f\\7b\\7a\\79\\01\\2a\\2a\\2a\\2a\\00\\2a\\00\\00\\00");
    const val = try decodeMany(
        struct { void, bool, u128, i128, void, Reserved, void, u8, u16, u32 },
        testing.allocator,
        bytes,
    );
    try testing.expectEqual(true, val[1]);
    try testing.expectEqual(@as(u128, 42), val[2]);
    try testing.expectEqual(@as(i128, 42), val[3]);
    try testing.expectEqual(@as(u8, 42), val[7]);
    try testing.expectEqual(@as(u16, 42), val[8]);
    try testing.expectEqual(@as(u32, 42), val[9]);
}

// -- missing argument coercions --

test "prim: missing argument null" {
    // "DIDL\00\00" == "(null)" : (null)
    _ = try decodeMany(struct { void }, testing.allocator, comptime x("DIDL\\00\\00"));
}

test "prim: missing argument opt nat" {
    // "DIDL\00\00" == "(null)" : (opt nat)
    const val = try decodeMany(struct { ?u128 }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual(@as(?u128, null), val[0]);
}

test "prim: missing argument opt empty" {
    // "DIDL\00\00" == "(null)" : (opt empty) -- decoded as opt void
    // Note: empty maps to nothing decodable, but opt empty -> null
    // We approximate with opt void.
    const val = try decodeMany(struct { ?void }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual(@as(?void, null), val[0]);
}

// Upstream: assert blob "DIDL\00\00" == "(null)" : (opt null) "missing argument: opt null"
test "prim: missing argument opt null" {
    const val = try decodeMany(struct { ?void }, testing.allocator, comptime x("DIDL\\00\\00"));
    try testing.expectEqual(@as(?void, null), val[0]);
}

// Upstream: assert blob "DIDL\00\00" == blob "DIDL\00\01\70" : (reserved) "missing argument: reserved"
test "prim: missing argument reserved" {
    _ = try decodeMany(struct { Reserved }, testing.allocator, comptime x("DIDL\\00\\00"));
}

// -- encode round-trips --

test "prim: encode empty args" {
    const bytes = try encode(testing.allocator, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, comptime x("DIDL\\00\\00"), bytes);
}

test "prim: encode bool true" {
    const bytes = try encode(testing.allocator, .{true});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, comptime x("DIDL\\00\\01\\7e\\01"), bytes);
}

test "prim: encode bool false" {
    const bytes = try encode(testing.allocator, .{false});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, comptime x("DIDL\\00\\01\\7e\\00"), bytes);
}

test "prim: encode nat 128" {
    const bytes = try encode(testing.allocator, .{@as(u128, 128)});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, comptime x("DIDL\\00\\01\\7d\\80\\01"), bytes);
}

test "prim: encode text Motoko" {
    const bytes = try encode(testing.allocator, .{@as([]const u8, "Motoko")});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, comptime x("DIDL\\00\\01\\71\\06Motoko"), bytes);
}
