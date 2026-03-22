// Conformance tests: reference.test.did
// https://github.com/dfinity/candid/blob/master/test/reference.test.did

const std = @import("std");
const lib = @import("lib.zig");
const testing = lib.testing;
const decode = lib.decode;
const x = lib.x;
const Principal = lib.Principal;
const Func = lib.Func;
const Service = lib.Service;
const Reserved = lib.Reserved;
const expectDecodeError = lib.expectDecodeError;
const expectDecodeManyError = lib.expectDecodeManyError;

// -- principal --

test "reference: principal ic0" {
    const bytes = "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x00 };
    const val = try decode(Principal, testing.allocator, bytes);
    defer testing.allocator.free(val.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{}, val.bytes);
}

test "reference: principal 3 bytes" {
    const bytes = "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x03, 0xca, 0xff, 0xee };
    const val = try decode(Principal, testing.allocator, bytes);
    defer testing.allocator.free(val.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.bytes);
}

test "reference: principal 9 bytes" {
    const bytes = "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x09, 0xef, 0xcd, 0xab, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const val = try decode(Principal, testing.allocator, bytes);
    defer testing.allocator.free(val.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xcd, 0xab, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 }, val.bytes);
}

test "reference: principal anonymous" {
    const bytes = "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x01, 0x04 };
    const val = try decode(Principal, testing.allocator, bytes);
    defer testing.allocator.free(val.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{0x04}, val.bytes);
}

test "reference: principal no tag" {
    // Flag byte is not 1 (it's 3 here - raw bytes without the 0x01 flag)
    try expectDecodeError(
        Principal,
        error.UnsupportedPrincipalRef,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x03, 0xca, 0xff, 0xee },
    );
}

test "reference: principal too short" {
    try expectDecodeError(
        Principal,
        error.EndOfStream,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x03, 0xca, 0xff },
    );
}

// -- func --

test "reference: func basic" {
    // func "w7x7r-cok77-xa"."a" : (func () -> ())
    const bytes = "DIDL" ++ &[_]u8{
        0x01,
        0x6a, 0x00, 0x00, 0x00, // func: 0 args, 0 results, 0 annotations
        0x01, 0x00, // 1 arg of type 0
        0x01, // func reference tag
        0x01, 0x03, 0xca, 0xff, 0xee, // principal tag + 3 bytes
        0x01, 0x61, // method name "a"
    };
    const val = try decode(Func, testing.allocator, bytes);
    defer testing.allocator.free(val.service.bytes);
    defer testing.allocator.free(val.method);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.service.bytes);
    try testing.expectEqualStrings("a", val.method);
}

test "reference: func with args" {
    // func "w7x7r-cok77-xa"."foo" : (func (principal) -> (nat))
    const bytes = "DIDL" ++ &[_]u8{
        0x01,
        0x6a, 0x01, 0x68, 0x01, 0x7d, 0x00, // func: 1 arg (principal), 1 result (nat), 0 annotations
        0x01, 0x00, 0x01, 0x01, 0x03, 0xca,
        0xff, 0xee, 0x03,
    } ++ "foo";
    const val = try decode(Func, testing.allocator, bytes);
    defer testing.allocator.free(val.service.bytes);
    defer testing.allocator.free(val.method);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.service.bytes);
    try testing.expectEqualStrings("foo", val.method);
}

test "reference: func wrong tag" {
    // Flag byte 0x00 instead of 0x01
    const bytes = "DIDL" ++ &[_]u8{
        0x01,
        0x6a,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x03,
        0xca,
        0xff,
        0xee,
        0x01,
        0x61,
    };
    try expectDecodeError(Func, error.UnsupportedPrincipalRef, bytes);
}

// -- service --

test "reference: service basic" {
    // service "w7x7r-cok77-xa" : (service {})
    const val = try decode(Service, testing.allocator, comptime x("DIDL\\01\\69\\00\\01\\00\\01\\03\\ca\\ff\\ee"));
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.principal.bytes);
}

test "reference: service with methods" {
    // service "w7x7r-cok77-xa" : (service { foo : (text) -> (nat) })
    const val = try decode(Service, testing.allocator, comptime x(
        "DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee",
    ));
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.principal.bytes);
}

// -- additional principal tests --

test "reference: principal different bytes" {
    // Same blob as principal 3 bytes but only 2 bytes -> different principal
    const bytes = "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x02, 0xca, 0xff };
    const val = try decode(Principal, testing.allocator, bytes);
    defer testing.allocator.free(val.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff }, val.bytes);
    // Not equal to the 3-byte principal
    try testing.expect(!std.mem.eql(u8, val.bytes, &[_]u8{ 0xca, 0xff, 0xee }));
}

test "reference: principal too long" {
    try expectDecodeError(
        Principal,
        error.TrailingBytes,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x03, 0xca, 0xff, 0xee, 0xee },
    );
}

test "reference: principal not construct" {
    // principal opcode (0x68) in the type table is rejected because
    // primitives are not valid type table entries
    try expectDecodeError(
        Principal,
        error.UnsupportedType,
        "DIDL" ++ &[_]u8{ 0x01, 0x68, 0x01, 0x00, 0x01, 0x03, 0xca, 0xff, 0xee },
    );
}

// -- additional service tests --

test "reference: service not principal" {
    // Wire type is principal (0x68), not service -> type mismatch
    try expectDecodeError(
        Service,
        error.TypeMismatch,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x68, 0x01, 0x03, 0xca, 0xff, 0xee },
    );
}

test "reference: service not primitive type" {
    // Service opcode (0x69) used as primitive type (not in type table)
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x69, 0x01, 0x03, 0xca, 0xff, 0xee },
    );
}

test "reference: service with two methods" {
    const bytes = comptime x(
        "DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\02\\03foo\\00\\04foo\\32\\00\\01\\01\\01\\03\\ca\\ff\\ee",
    );
    const val = try decode(Service, testing.allocator, bytes);
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.principal.bytes);
}

test "reference: service decodes at service {}" {
    // service { foo : (text) -> (nat) } decodes at service {}
    const bytes = comptime x(
        "DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee",
    );
    const val = try decode(Service, testing.allocator, bytes);
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.principal.bytes);
}

test "reference: service unicode" {
    const bytes = comptime x(
        "DIDL\\05i\\02\\03foo\\01\\04\\f0\\9f\\90\\82\\02j\\00\\00\\01\\02j\\01\\03\\01\\04\\01\\01n|l\\00\\01\\00\\01\\00",
    );
    const val = try decode(Service, testing.allocator, bytes);
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{}, val.principal.bytes);
}

test "reference: service invalid unicode" {
    // Method name \e2\28\a1 is invalid UTF-8; detected during type table parsing
    try expectDecodeError(
        Reserved,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03\\e2\\28\\a1\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service duplicate method" {
    // Duplicate method name "foo" -> sorted order violation in type table
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\02\\03foo\\00\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

// -- additional func tests --

test "reference: func query" {
    const QueryFunc = lib.QueryFunc;
    const bytes = "DIDL" ++ &[_]u8{
        0x01,
        0x6a, 0x01, 0x71, 0x01, 0x7d, 0x01, 0x01, // func (text) -> (nat) query
        0x01, 0x00, 0x01, 0x01, 0x03, 0xca, 0xff,
        0xee, 0x03,
    } ++ "foo";
    const val = try decode(QueryFunc, testing.allocator, bytes);
    defer testing.allocator.free(val.service.bytes);
    defer testing.allocator.free(val.method);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.service.bytes);
    try testing.expectEqualStrings("foo", val.method);
}

test "reference: func composite query" {
    const CQFunc = lib.CompositeQueryFunc;
    const bytes = "DIDL" ++ &[_]u8{
        0x01,
        0x6a, 0x01, 0x71, 0x01, 0x7d, 0x01, 0x03, // func (text) -> (nat) composite_query
        0x01, 0x00, 0x01, 0x01, 0x03, 0xca, 0xff,
        0xee, 0x03,
    } ++ "foo";
    const val = try decode(CQFunc, testing.allocator, bytes);
    defer testing.allocator.free(val.service.bytes);
    defer testing.allocator.free(val.method);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.service.bytes);
    try testing.expectEqualStrings("foo", val.method);
}

test "reference: func unicode" {
    // func (int, nat) -> (service {}) query - annotation byte 0x01
    const QueryFunc = lib.QueryFunc;
    const bytes = comptime x(
        "DIDL\\02j\\02|}\\01\\01\\01\\01i\\00\\01\\00\\01\\01\\00\\04\\f0\\9f\\90\\82",
    );
    const val = try decode(QueryFunc, testing.allocator, bytes);
    defer testing.allocator.free(val.service.bytes);
    defer testing.allocator.free(val.method);
    try testing.expectEqualSlices(u8, &[_]u8{}, val.service.bytes);
    try testing.expectEqualStrings("\xf0\x9f\x90\x82", val.method);
}

test "reference: func not primitive" {
    // func opcode (0x6a) used as primitive type, not in type table
    try expectDecodeError(
        Func,
        error.UnsupportedType,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x6a, 0x01, 0x01, 0x03, 0xca, 0xff, 0xee, 0x01, 0x61 },
    );
}

test "reference: func no tag" {
    // No func reference tag byte
    try expectDecodeError(
        Func,
        error.UnsupportedType,
        "DIDL" ++ &[_]u8{ 0x00, 0x01, 0x6a, 0x01, 0x03, 0xca, 0xff, 0xee, 0x01, 0x61 },
    );
}

// -- service method count/ordering tests --

test "reference: service too long" {
    // service declares 3 methods but type table has data for only 2
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\03\\03foo\\00\\04foo\\32\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service too short" {
    // service declares 1 method but type table has data for 2
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03foo\\00\\04foo\\32\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service unsorted" {
    // Methods "foo2" before "foo" (lexicographic order violation)
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\02\\04foo\\32\\00\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service unsorted (but sorted by hash)" {
    // "foobarbaz" before "foobar" - sorted by hash but not lexicographically
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\02\\09foobarbaz\\00\\06foobar\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

// -- service method type validation tests --

test "reference: service { foo: principal }" {
    // Method "foo" references principal type (0x68), not a func type
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03foo\\68\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service { foo: opt bool } (opt before service)" {
    // Type table: [0: opt bool, 1: service { foo: type 0 }]
    // Method "foo" references opt bool, not a func type
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\6e\\7e\\69\\01\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

test "reference: service { foo: opt bool } (opt after service)" {
    // Type table: [0: service { foo: type 1 }, 1: opt bool]
    // Method "foo" references opt bool, not a func type
    try expectDecodeError(
        Service,
        error.UnsupportedType,
        comptime x("DIDL\\02\\69\\01\\03foo\\01\\6e\\7e\\01\\01\\01\\03\\ca\\ff\\ee"),
    );
}

// -- func annotation tests --

test "reference: func unknown annotation" {
    // Annotation byte 0x80 0x01 (LEB 128) is unknown/invalid
    try expectDecodeError(
        Func,
        error.UnsupportedType,
        comptime x("DIDL\\01\\6a\\01\\71\\01\\7d\\01\\80\\01\\01\\00\\01\\01\\03\\ca\\ff\\ee\\03foo"),
    );
}

test "reference: func service not in type table" {
    // Func arg is service (0x69) used directly, not via type table
    try expectDecodeError(
        Func,
        error.UnsupportedType,
        comptime x("DIDL\\01\\6a\\01\\69\\01\\7d\\00\\01\\00\\01\\01\\03\\ca\\ff\\ee\\03foo"),
    );
}

test "reference: func invalid annotation" {
    // Wire func has composite_query but decoded as Func (no annotation) -> mismatch
    try expectDecodeError(
        Func,
        error.TypeMismatch,
        comptime x("DIDL\\01\\6a\\01\\71\\01\\7d\\01\\03\\01\\00\\01\\01\\03\\ca\\ff\\ee\\03foo"),
    );
}

// -- subtype tests --
// These test subtype relations on service/func types. We use isSubtype
// with constructed type table entries, matching how subtypes.zig works.

const decoding = @import("../decoding.zig");
const TypeEntry = decoding.TypeEntry;
const FieldEntry = decoding.FieldEntry;
const isSubtype = decoding.isSubtype;

const type_text: i32 = -15;
const type_nat: i32 = -3;
const type_func: i32 = -22;
const type_service: i32 = -23;

fn svc(methods: []const FieldEntry) TypeEntry {
    return .{ .opcode = type_service, .fields = methods };
}

fn func_(args: []const i32, results: []const i32) TypeEntry {
    return .{ .opcode = type_func, .func_args = args, .func_results = results };
}

fn funcA(args: []const i32, results: []const i32, ann: u8) TypeEntry {
    return .{ .opcode = type_func, .func_args = args, .func_results = results, .annotations = ann };
}

fn meth(comptime name: []const u8, type_ref: i32) FieldEntry {
    return .{ .hash = comptime lib.candid.fieldHash(name), .type_ref = type_ref };
}

test "reference: service {} !<: service { foo : (text) -> (nat) }" {
    const table = [_]TypeEntry{
        svc(&.{}), // 0: service {}
        func_(&.{type_text}, &.{type_nat}), // 1: func (text) -> (nat)
        svc(&.{meth("foo", 1)}), // 2: service { foo : (text) -> (nat) }
    };
    try testing.expect(!isSubtype(&table, 0, 2));
}

test "reference: service { foo query } !<: service { foo }" {
    const table = [_]TypeEntry{
        funcA(&.{type_text}, &.{type_nat}, 1), // 0: func (text) -> (nat) query
        svc(&.{meth("foo", 0)}), // 1: service { foo : func query }
        func_(&.{type_text}, &.{type_nat}), // 2: func (text) -> (nat)
        svc(&.{meth("foo", 2)}), // 3: service { foo : func }
    };
    try testing.expect(!isSubtype(&table, 1, 3));
}

test "reference: service { foo } !<: service { foo query }" {
    const table = [_]TypeEntry{
        func_(&.{type_text}, &.{type_nat}), // 0: func (text) -> (nat)
        svc(&.{meth("foo", 0)}), // 1: service { foo : func }
        funcA(&.{type_text}, &.{type_nat}, 1), // 2: func (text) -> (nat) query
        svc(&.{meth("foo", 2)}), // 3: service { foo : func query }
    };
    try testing.expect(!isSubtype(&table, 1, 3));
}

test "reference: service { foo } decodes at service {}" {
    // service with methods decoded as Service (no expected methods) succeeds
    const val = try decode(Service, testing.allocator, comptime x(
        "DIDL\\02\\6a\\01\\71\\01\\7d\\00\\69\\01\\03foo\\00\\01\\01\\01\\03\\ca\\ff\\ee",
    ));
    defer testing.allocator.free(val.principal.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0xff, 0xee }, val.principal.bytes);
}

test "reference: func () -> () !<: func (text) -> (nat)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        func_(&.{type_text}, &.{type_nat}), // 1: func (text) -> (nat)
    };
    try testing.expect(!isSubtype(&table, 0, 1));
}

test "reference: func (text) -> (nat) decodes at func (text, opt text) -> ()" {
    // func subtype coercion: wire has (text) -> (nat), expected has
    // (text, opt text) -> (). Extra opt arg is omittable, extra result
    // nat is ignored. This is tested via isSubtype.
    const type_opt: i32 = -18;
    const table = [_]TypeEntry{
        func_(&.{type_text}, &.{type_nat}), // 0: func (text) -> (nat)
        .{ .opcode = type_opt, .inner = type_text }, // 1: opt text
        func_(&.{ type_text, 1 }, &.{}), // 2: func (text, opt text) -> ()
    };
    try testing.expect(isSubtype(&table, 0, 2));
}
