// Conformance tests: spacebomb.test.did
// https://github.com/dfinity/candid/blob/master/test/spacebomb.test.did
//
// Messages in this test all take a lot of time, memory and stack space to
// decode with a naive implementation. The upstream test suite marks all of
// them as !: (must fail).
//
// Our decoder handles zero-sized type skipping in O(1) via isZeroSized(),
// so tests that only require skipping (extra arguments and subtype
// coercion) succeed efficiently. Tests that require allocating huge
// arrays fail with OutOfMemory or EndOfStream.

const lib = @import("lib.zig");
const testing = lib.testing;
const decode = lib.decode;
const decodeMany = lib.decodeMany;
const Reserved = lib.Reserved;
const expectDecodeError = lib.expectDecodeError;
const expectDecodeManyError = lib.expectDecodeManyError;

// -- Plain decoding (unused arguments) --
// All skipped as extra args via skipValue. Zero-sized types are O(1).

test "spacebomb: vec null extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x7f, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 },
    );
}

test "spacebomb: vec reserved extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x70, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 },
    );
}

test "spacebomb: zero-sized record extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{
            0x04, 0x6c, 0x03, 0x00, 0x7f, 0x01, 0x01, 0x02, 0x02,
            0x6c, 0x01, 0x00, 0x70, 0x6c, 0x00, 0x6d, 0x00, 0x01,
            0x03, 0x80, 0x94, 0xeb, 0xdc, 0x03,
        },
    );
}

test "spacebomb: vec vec null extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{
            0x02, 0x6d, 0x01, 0x6d, 0x7f,
            0x01, 0x00, 0x05, 0xff, 0xff,
            0x3f, 0xff, 0xff, 0x3f, 0xff,
            0xff, 0x3f, 0xff, 0xff, 0x3f,
            0xff, 0xff, 0x3f,
        },
    );
}

test "spacebomb: vec record empty extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{ 0x02, 0x6d, 0x01, 0x6c, 0x00, 0x01, 0x00, 0x80, 0xad, 0xe2, 0x04 },
    );
}

test "spacebomb: vec opt record extra argument" {
    _ = try decodeMany(
        struct {},
        testing.allocator,
        "DIDL" ++ &[_]u8{
            0x17,
            0x6c,
            0x02,
            0x01,
            0x7f,
            0x02,
            0x7f,
            0x6c,
            0x02,
            0x01,
            0x00,
            0x02,
            0x00,
            0x6c,
            0x02,
            0x00,
            0x01,
            0x01,
            0x01,
            0x6c,
            0x02,
            0x00,
            0x02,
            0x01,
            0x02,
            0x6c,
            0x02,
            0x00,
            0x03,
            0x01,
            0x03,
            0x6c,
            0x02,
            0x00,
            0x04,
            0x01,
            0x04,
            0x6c,
            0x02,
            0x00,
            0x05,
            0x01,
            0x05,
            0x6c,
            0x02,
            0x00,
            0x06,
            0x01,
            0x06,
            0x6c,
            0x02,
            0x00,
            0x07,
            0x01,
            0x07,
            0x6c,
            0x02,
            0x00,
            0x08,
            0x01,
            0x08,
            0x6c,
            0x02,
            0x00,
            0x09,
            0x01,
            0x09,
            0x6c,
            0x02,
            0x00,
            0x0a,
            0x01,
            0x0a,
            0x6c,
            0x02,
            0x00,
            0x0b,
            0x01,
            0x0b,
            0x6c,
            0x02,
            0x00,
            0x0c,
            0x01,
            0x0c,
            0x6c,
            0x02,
            0x00,
            0x0d,
            0x02,
            0x0d,
            0x6c,
            0x02,
            0x00,
            0x0e,
            0x01,
            0x0e,
            0x6c,
            0x02,
            0x00,
            0x0f,
            0x01,
            0x0f,
            0x6c,
            0x02,
            0x00,
            0x10,
            0x01,
            0x10,
            0x6c,
            0x02,
            0x00,
            0x11,
            0x01,
            0x11,
            0x6c,
            0x02,
            0x00,
            0x12,
            0x01,
            0x12,
            0x6c,
            0x02,
            0x00,
            0x13,
            0x01,
            0x13,
            0x6e,
            0x14,
            0x6d,
            0x15,
            0x01,
            0x16,
            0x02,
            0x01,
            0x01,
        },
    );
}

// -- Decoding to actual type (not ignored) --
// All rejected by the max_zero_sized_vec_len cap (default 1M) or data_len check.

test "spacebomb: vec null not ignored" {
    try expectDecodeError(
        []const ?u128,
        error.EndOfStream,
        "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x7f, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 },
    );
}

test "spacebomb: vec reserved not ignored" {
    try expectDecodeError(
        []const Reserved,
        error.EndOfStream,
        "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x70, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 },
    );
}

test "spacebomb: zero-sized record not ignored" {
    try expectDecodeError(
        []const struct { void, struct { Reserved }, struct {} },
        error.EndOfStream,
        "DIDL" ++ &[_]u8{
            0x04, 0x6c, 0x03, 0x00, 0x7f, 0x01, 0x01, 0x02, 0x02,
            0x6c, 0x01, 0x00, 0x70, 0x6c, 0x00, 0x6d, 0x00, 0x01,
            0x03, 0x80, 0x94, 0xeb, 0xdc, 0x03,
        },
    );
}

test "spacebomb: vec vec null not ignored" {
    try expectDecodeError(
        []const []const void,
        error.EndOfStream,
        "DIDL" ++ &[_]u8{
            0x02, 0x6d, 0x01, 0x6d, 0x7f,
            0x01, 0x00, 0x05, 0xff, 0xff,
            0x3f, 0xff, 0xff, 0x3f, 0xff,
            0xff, 0x3f, 0xff, 0xff, 0x3f,
            0xff, 0xff, 0x3f,
        },
    );
}

test "spacebomb: vec record empty not ignored" {
    try expectDecodeError(
        []const struct {},
        error.EndOfStream,
        "DIDL" ++ &[_]u8{ 0x02, 0x6d, 0x01, 0x6c, 0x00, 0x01, 0x00, 0x80, 0xad, 0xe2, 0x04 },
    );
}

// -- Decoding under opt (subtyping) --
// Type mismatch under opt triggers skipValue which handles zero-sized in O(1).

test "spacebomb: vec null subtyping" {
    const val = try decode(?u128, testing.allocator, "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x7f, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 });
    try testing.expectEqual(@as(?u128, null), val);
}

test "spacebomb: vec reserved subtyping" {
    const val = try decode(?u128, testing.allocator, "DIDL" ++ &[_]u8{ 0x01, 0x6d, 0x70, 0x01, 0x00, 0x80, 0x94, 0xeb, 0xdc, 0x03 });
    try testing.expectEqual(@as(?u128, null), val);
}

test "spacebomb: zero-sized record subtyping" {
    const val = try decode(?u128, testing.allocator, "DIDL" ++ &[_]u8{
        0x04, 0x6c, 0x03, 0x00, 0x7f, 0x01, 0x01, 0x02, 0x02,
        0x6c, 0x01, 0x00, 0x70, 0x6c, 0x00, 0x6d, 0x00, 0x01,
        0x03, 0x80, 0x94, 0xeb, 0xdc, 0x03,
    });
    try testing.expectEqual(@as(?u128, null), val);
}

test "spacebomb: vec vec null subtyping" {
    const val = try decode([]const ?u128, testing.allocator, "DIDL" ++ &[_]u8{
        0x02, 0x6d, 0x01, 0x6d, 0x7f,
        0x01, 0x00, 0x05, 0xff, 0xff,
        0x3f, 0xff, 0xff, 0x3f, 0xff,
        0xff, 0x3f, 0xff, 0xff, 0x3f,
        0xff, 0xff, 0x3f,
    });
    defer testing.allocator.free(val);
    try testing.expectEqual(@as(usize, 5), val.len);
    for (val) |v| try testing.expectEqual(@as(?u128, null), v);
}

test "spacebomb: vec record empty subtyping" {
    const val = try decode(?u128, testing.allocator, "DIDL" ++ &[_]u8{ 0x02, 0x6d, 0x01, 0x6c, 0x00, 0x01, 0x00, 0x80, 0xad, 0xe2, 0x04 });
    try testing.expectEqual(@as(?u128, null), val);
}

test "spacebomb: vec opt record subtyping" {
    const val = try decode([]const ?struct {}, testing.allocator, "DIDL" ++ &[_]u8{
        0x17,
        0x6c,
        0x02,
        0x01,
        0x7f,
        0x02,
        0x7f,
        0x6c,
        0x02,
        0x01,
        0x00,
        0x02,
        0x00,
        0x6c,
        0x02,
        0x00,
        0x01,
        0x01,
        0x01,
        0x6c,
        0x02,
        0x00,
        0x02,
        0x01,
        0x02,
        0x6c,
        0x02,
        0x00,
        0x03,
        0x01,
        0x03,
        0x6c,
        0x02,
        0x00,
        0x04,
        0x01,
        0x04,
        0x6c,
        0x02,
        0x00,
        0x05,
        0x01,
        0x05,
        0x6c,
        0x02,
        0x00,
        0x06,
        0x01,
        0x06,
        0x6c,
        0x02,
        0x00,
        0x07,
        0x01,
        0x07,
        0x6c,
        0x02,
        0x00,
        0x08,
        0x01,
        0x08,
        0x6c,
        0x02,
        0x00,
        0x09,
        0x01,
        0x09,
        0x6c,
        0x02,
        0x00,
        0x0a,
        0x01,
        0x0a,
        0x6c,
        0x02,
        0x00,
        0x0b,
        0x01,
        0x0b,
        0x6c,
        0x02,
        0x00,
        0x0c,
        0x01,
        0x0c,
        0x6c,
        0x02,
        0x00,
        0x0d,
        0x02,
        0x0d,
        0x6c,
        0x02,
        0x00,
        0x0e,
        0x01,
        0x0e,
        0x6c,
        0x02,
        0x00,
        0x0f,
        0x01,
        0x0f,
        0x6c,
        0x02,
        0x00,
        0x10,
        0x01,
        0x10,
        0x6c,
        0x02,
        0x00,
        0x11,
        0x01,
        0x11,
        0x6c,
        0x02,
        0x00,
        0x12,
        0x01,
        0x12,
        0x6c,
        0x02,
        0x00,
        0x13,
        0x01,
        0x13,
        0x6e,
        0x14,
        0x6d,
        0x15,
        0x01,
        0x16,
        0x05,
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
    });
    defer testing.allocator.free(val);
}
