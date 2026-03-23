// Conformance tests translated from the dfinity/candid reference test suite.
// https://github.com/dfinity/candid/blob/master/test/subtypes.test.did
//
// These tests verify the isSubtype function which implements the candid
// subtype checking rules. Each test constructs a type table with the
// relevant type entries and checks the subtype relation directly.
//
// Tests are named: "subtypes: <description>"

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const decoding = @import("../decoding.zig");
const TypeEntry = decoding.TypeEntry;
const FieldEntry = decoding.FieldEntry;
const isSubtype = decoding.isSubtype;

const type_null = types.type_null;
const type_bool = types.type_bool;
const type_nat = types.type_nat;
const type_int = types.type_int;
const type_nat8 = types.type_nat8;
const type_empty = types.type_empty;
const type_reserved = types.type_reserved;
const type_opt = types.type_opt;
const type_vec = types.type_vec;
const type_record = types.type_record;
const type_variant = types.type_variant;
const type_func = types.type_func;

// Type table entry constructors

fn rec(fields: []const FieldEntry) TypeEntry {
    return .{ .opcode = type_record, .fields = fields };
}

fn vnt(fields: []const FieldEntry) TypeEntry {
    return .{ .opcode = type_variant, .fields = fields };
}

fn opt_(inner: i32) TypeEntry {
    return .{ .opcode = type_opt, .inner = inner };
}

fn vec_(inner: i32) TypeEntry {
    return .{ .opcode = type_vec, .inner = inner };
}

fn func_(args: []const i32, results: []const i32) TypeEntry {
    return .{ .opcode = type_func, .func_args = args, .func_results = results };
}

fn fld(hash: u32, type_ref: i32) FieldEntry {
    return .{ .hash = hash, .type_ref = type_ref };
}

// Assertion helpers

fn sub(table: []const TypeEntry, t1: i32, t2: i32) !void {
    try testing.expect(try isSubtype(table, t1, t2, testing.allocator));
}

fn notSub(table: []const TypeEntry, t1: i32, t2: i32) !void {
    try testing.expect(!try isSubtype(table, t1, t2, testing.allocator));
}

// -- reflexive cases --

test "subtypes: null <: null" {
    try sub(&.{}, type_null, type_null);
}

test "subtypes: bool <: bool" {
    try sub(&.{}, type_bool, type_bool);
}

test "subtypes: nat <: nat" {
    try sub(&.{}, type_nat, type_nat);
}

test "subtypes: int <: int" {
    try sub(&.{}, type_int, type_int);
}

// -- basic cases --

test "subtypes: nat <: int" {
    try sub(&.{}, type_nat, type_int);
}

test "subtypes: null </: nat" {
    try notSub(&.{}, type_null, type_nat);
}

test "subtypes: nat </: nat8" {
    try notSub(&.{}, type_nat, type_nat8);
}

test "subtypes: nat8 </: nat" {
    try notSub(&.{}, type_nat8, type_nat);
}

// -- options are supertypes of anything --

test "subtypes: nat <: opt bool" {
    const table = [_]TypeEntry{opt_(type_bool)};
    try sub(&table, type_nat, 0);
}

test "subtypes: opt bool <: opt bool" {
    const table = [_]TypeEntry{opt_(type_bool)};
    try sub(&table, 0, 0);
}

test "subtypes: bool <: opt bool" {
    const table = [_]TypeEntry{opt_(type_bool)};
    try sub(&table, type_bool, 0);
}

test "subtypes: mu opt <: opt opt nat" {
    const table = [_]TypeEntry{
        opt_(0), // 0: mu opt (self-ref)
        opt_(type_nat), // 1: opt nat
        opt_(1), // 2: opt opt nat
    };
    try sub(&table, 0, 2);
}

// -- optional record fields --

test "subtypes: record {} <: record {}" {
    const table = [_]TypeEntry{rec(&.{})};
    try sub(&table, 0, 0);
}

test "subtypes: record {} <: record { a : opt empty }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        opt_(type_empty), // 1: opt empty
        rec(&.{fld(97, 1)}), // 2: record { a : opt empty }
    };
    try sub(&table, 0, 2);
}

test "subtypes: record {} <: record { a : opt null }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        opt_(type_null), // 1: opt null
        rec(&.{fld(97, 1)}), // 2: record { a : opt null }
    };
    try sub(&table, 0, 2);
}

test "subtypes: record {} <: record { a : reserved }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        rec(&.{fld(97, type_reserved)}), // 1: record { a : reserved }
    };
    try sub(&table, 0, 1);
}

test "subtypes: record {} </: record { a : empty }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        rec(&.{fld(97, type_empty)}), // 1: record { a : empty }
    };
    try notSub(&table, 0, 1);
}

test "subtypes: record {} </: record { a : nat }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        rec(&.{fld(97, type_nat)}), // 1: record { a : nat }
    };
    try notSub(&table, 0, 1);
}

test "subtypes: record {} <: record { a : null }" {
    const table = [_]TypeEntry{
        rec(&.{}), // 0: record {}
        rec(&.{fld(97, type_null)}), // 1: record { a : null }
    };
    try sub(&table, 0, 1);
}

// -- optional func results (covariant) --

test "subtypes: func () -> () <: func () -> ()" {
    const table = [_]TypeEntry{func_(&.{}, &.{})};
    try sub(&table, 0, 0);
}

test "subtypes: func () -> () <: func () -> (opt empty)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        opt_(type_empty), // 1: opt empty
        func_(&.{}, &.{1}), // 2: func () -> (opt empty)
    };
    try sub(&table, 0, 2);
}

test "subtypes: func () -> () <: func () -> (opt null)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        opt_(type_null), // 1: opt null
        func_(&.{}, &.{1}), // 2: func () -> (opt null)
    };
    try sub(&table, 0, 2);
}

test "subtypes: func () -> () <: func () -> (reserved)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        func_(&.{}, &.{type_reserved}), // 1: func () -> (reserved)
    };
    try sub(&table, 0, 1);
}

test "subtypes: func () -> () </: func () -> (empty)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        func_(&.{}, &.{type_empty}), // 1: func () -> (empty)
    };
    try notSub(&table, 0, 1);
}

test "subtypes: func () -> () </: func () -> (nat)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        func_(&.{}, &.{type_nat}), // 1: func () -> (nat)
    };
    try notSub(&table, 0, 1);
}

test "subtypes: func () -> () <: func () -> (null)" {
    const table = [_]TypeEntry{
        func_(&.{}, &.{}), // 0: func () -> ()
        func_(&.{}, &.{type_null}), // 1: func () -> (null)
    };
    try sub(&table, 0, 1);
}

// -- optional func arguments (contravariant) --

test "subtypes: func (opt empty) -> () <: func () -> ()" {
    const table = [_]TypeEntry{
        opt_(type_empty), // 0: opt empty
        func_(&.{0}, &.{}), // 1: func (opt empty) -> ()
        func_(&.{}, &.{}), // 2: func () -> ()
    };
    try sub(&table, 1, 2);
}

test "subtypes: func (opt null) -> () <: func () -> ()" {
    const table = [_]TypeEntry{
        opt_(type_null), // 0: opt null
        func_(&.{0}, &.{}), // 1: func (opt null) -> ()
        func_(&.{}, &.{}), // 2: func () -> ()
    };
    try sub(&table, 1, 2);
}

test "subtypes: func (reserved) -> () <: func () -> ()" {
    const table = [_]TypeEntry{
        func_(&.{type_reserved}, &.{}), // 0: func (reserved) -> ()
        func_(&.{}, &.{}), // 1: func () -> ()
    };
    try sub(&table, 0, 1);
}

test "subtypes: func (empty) -> () </: func () -> ()" {
    const table = [_]TypeEntry{
        func_(&.{type_empty}, &.{}), // 0: func (empty) -> ()
        func_(&.{}, &.{}), // 1: func () -> ()
    };
    try notSub(&table, 0, 1);
}

test "subtypes: func (nat) -> () </: func () -> ()" {
    const table = [_]TypeEntry{
        func_(&.{type_nat}, &.{}), // 0: func (nat) -> ()
        func_(&.{}, &.{}), // 1: func () -> ()
    };
    try notSub(&table, 0, 1);
}

test "subtypes: func (null) -> () <: func () -> ()" {
    const table = [_]TypeEntry{
        func_(&.{type_null}, &.{}), // 0: func (null) -> ()
        func_(&.{}, &.{}), // 1: func () -> ()
    };
    try sub(&table, 0, 1);
}

// -- variants --

test "subtypes: variant {} <: variant {}" {
    const table = [_]TypeEntry{vnt(&.{})};
    try sub(&table, 0, 0);
}

test "subtypes: variant {} <: variant {0 : nat}" {
    const table = [_]TypeEntry{
        vnt(&.{}), // 0: variant {}
        vnt(&.{fld(0, type_nat)}), // 1: variant {0 : nat}
    };
    try sub(&table, 0, 1);
}

test "subtypes: variant {0 : nat} <: variant {0 : nat}" {
    const table = [_]TypeEntry{vnt(&.{fld(0, type_nat)})};
    try sub(&table, 0, 0);
}

test "subtypes: variant {0 : bool} </: variant {0 : nat}" {
    const table = [_]TypeEntry{
        vnt(&.{fld(0, type_bool)}), // 0: variant {0 : bool}
        vnt(&.{fld(0, type_nat)}), // 1: variant {0 : nat}
    };
    try notSub(&table, 0, 1);
}

test "subtypes: variant {0 : bool} </: variant {1 : bool}" {
    const table = [_]TypeEntry{
        vnt(&.{fld(0, type_bool)}), // 0: variant {0 : bool}
        vnt(&.{fld(1, type_bool)}), // 1: variant {1 : bool}
    };
    try notSub(&table, 0, 1);
}

// -- infinite types (records) --

test "subtypes: (mu record) <: (mu record)" {
    const table = [_]TypeEntry{rec(&.{fld(0, 0)})};
    try sub(&table, 0, 0);
}

// Upstream has this commented out:
// test "subtypes: (mu record) </: empty"

test "subtypes: empty <: (mu record)" {
    const table = [_]TypeEntry{rec(&.{fld(0, 0)})};
    try sub(&table, type_empty, 0);
}

test "subtypes: (mu record) <: record {mu record}" {
    const table = [_]TypeEntry{
        rec(&.{fld(0, 0)}), // 0: mu record {0: self}
        rec(&.{fld(0, 0)}), // 1: record {0: type 0} (structurally equivalent)
    };
    try sub(&table, 0, 1);
}

test "subtypes: record {mu record} <: (mu record)" {
    const table = [_]TypeEntry{
        rec(&.{fld(0, 1)}), // 0: record {0: type 1}
        rec(&.{fld(0, 1)}), // 1: mu record {0: self}
    };
    try sub(&table, 0, 1);
}

test "subtypes: (mu record) <: (mu (record opt))" {
    const table = [_]TypeEntry{
        rec(&.{fld(0, 0)}), // 0: mu record {0: self}
        rec(&.{fld(0, 2)}), // 1: mu record_opt {0: opt self}
        opt_(1), // 2: opt type 1
    };
    try sub(&table, 0, 1);
}

// -- infinite types (variants) --

test "subtypes: (mu variant) <: (mu variant)" {
    const table = [_]TypeEntry{vnt(&.{fld(0, 0)})};
    try sub(&table, 0, 0);
}

test "subtypes: (mu variant) </: empty" {
    const table = [_]TypeEntry{vnt(&.{fld(0, 0)})};
    try notSub(&table, 0, type_empty);
}

test "subtypes: empty <: (mu variant)" {
    const table = [_]TypeEntry{vnt(&.{fld(0, 0)})};
    try sub(&table, type_empty, 0);
}

test "subtypes: (mu variant) <: variant {mu variant}" {
    const table = [_]TypeEntry{
        vnt(&.{fld(0, 0)}), // 0: mu variant
        vnt(&.{fld(0, 0)}), // 1: variant {0: type 0}
    };
    try sub(&table, 0, 1);
}

test "subtypes: variant {mu variant} <: (mu variant)" {
    const table = [_]TypeEntry{
        vnt(&.{fld(0, 1)}), // 0: variant {0: type 1}
        vnt(&.{fld(0, 1)}), // 1: mu variant {0: self}
    };
    try sub(&table, 0, 1);
}

// -- infinite types (vec) --

test "subtypes: (mu vec) <: (mu vec)" {
    const table = [_]TypeEntry{vec_(0)};
    try sub(&table, 0, 0);
}

test "subtypes: (mu vec) </: empty" {
    const table = [_]TypeEntry{vec_(0)};
    try notSub(&table, 0, type_empty);
}

test "subtypes: empty <: (mu vec)" {
    const table = [_]TypeEntry{vec_(0)};
    try sub(&table, type_empty, 0);
}

test "subtypes: (mu vec) <: vec {mu vec}" {
    const table = [_]TypeEntry{
        vec_(0), // 0: mu vec
        vec_(0), // 1: vec {type 0}
    };
    try sub(&table, 0, 1);
}

test "subtypes: vec {mu vec} <: (mu vec)" {
    const table = [_]TypeEntry{
        vec_(1), // 0: vec {type 1}
        vec_(1), // 1: mu vec {self}
    };
    try sub(&table, 0, 1);
}

// -- future types --

test "subtypes: (future type) <: (opt empty)" {
    const table = [_]TypeEntry{
        .{ .opcode = -25 }, // 0: future type
        opt_(type_empty), // 1: opt empty
    };
    try sub(&table, 0, 1);
}

test "subtypes: (future type) </: (nat)" {
    const table = [_]TypeEntry{
        .{ .opcode = -25 }, // 0: future type
    };
    try notSub(&table, 0, type_nat);
}

test "subtypes: subtype check works with >64 type table entries" {
    // Build a table with 65 entries. Entries 0 and 1 are identical
    // records that should be subtypes of each other. Entries 2-64
    // are padding (opt null).
    var table: [65]TypeEntry = undefined;
    const fields = &[_]FieldEntry{fld(0, type_nat)};
    table[0] = rec(fields);
    table[1] = rec(fields);
    for (2..65) |i| {
        table[i] = opt_(type_null);
    }
    try sub(&table, 0, 1);
}
