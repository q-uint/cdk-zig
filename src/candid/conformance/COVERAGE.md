# Conformance Test Coverage

Test vectors from the [dfinity/candid](https://github.com/dfinity/candid/tree/master/test)
reference test suite. Each checkbox indicates a test vector is implemented in
the corresponding `.zig` file. Textual (non-blob) assertions are marked N/A
since this decoder only handles binary encoding.

## prim.test.did (prim.zig)

All 168 blob vectors covered, plus 11 extra implementation tests.

- [x] empty
- [x] no magic bytes
- [x] wrong magic bytes (DADL)
- [x] wrong magic bytes (DADL\00\00)
- [x] overlong typ table length
- [x] overlong arg length
- [x] DIDL\00\00 (valid empty args)
- [x] nullary: too long
- [x] Additional parameters are ignored
- [x] Not a primitive type
- [x] Out of range type
- [x] missing argument: nat fails
- [x] missing argument: empty fails
- [x] missing argument: null
- [x] missing argument: opt empty
- [x] missing argument: opt null
- [x] missing argument: opt nat
- [x] missing argument: reserved
- [x] null
- [x] wrong type
- [x] null: too long
- [x] bool: false
- [x] bool: true
- [x] bool: missing
- [x] bool: out of range (0x02)
- [x] bool: out of range (0xff)
- [x] nat: 0
- [x] nat: 1
- [x] nat: 0x7f (127)
- [x] nat: leb (two bytes)
- [x] nat: leb (two bytes, all bits)
- [x] nat: leb too short
- [x] nat: leb overlong (0x80 0x00)
- [x] nat: leb overlong (0xff 0x00)
- [x] nat: big number
- [x] int: 0
- [x] int: 1
- [x] int: -1
- [x] int: -64
- [x] int: leb (two bytes)
- [x] int: leb too short
- [x] int: leb overlong (0s)
- [x] int: leb overlong (1s)
- [x] int: leb not overlong when signed (0xff 0x00)
- [x] int: leb not overlong when signed (0x80 0x7f)
- [x] int: big number
- [x] int: negative big number
- [x] nat <: int: 0
- [x] nat <: int: 1
- [x] nat <: int: 127
- [x] nat <: int: 128
- [x] nat <: int: 16383
- [x] nat8: 0, 1, 255, too short, too long
- [x] nat16: 0, 1, 255, 256, 65535, too short (x2), too long
- [x] nat32: 0, 1, 255, 256, 65535, 4294967295, too short (x4), too long
- [x] nat64: 0, 1, 255, 256, 65535, 4294967295, max, too short (x8), too long
- [x] int8: 0, 1, -1, too short, too long
- [x] int16: 0, 1, 255, 256, -1, too short (x2), too long
- [x] int32: 0, 1, 255, 256, 65535, -1, too short (x4), too long
- [x] int64: 0, 1, 255, 256, 65535, 4294967295, -1, too short (x8), too long
- [x] float32: 0, 3, 0.5, -0.5, too short, too long
- [x] float64: 0, 3, 0.5, -0.5, NaN, max value, too short, too long
- [x] text: empty string, Motoko, too long, too short, overlong length leb
- [x] text: Unicode, Unicode escape, Unicode escape with underscore
- [x] text: Unicode escape (unclosed), Invalid utf8, Unicode overshoots
- [x] text: Escape sequences
- [x] reserved from null/bool/nat/text, extra value, too short text, invalid utf8
- [x] cannot decode empty type
- [x] okay to decode non-empty value
- [x] multiple arguments

## construct.test.did (construct.zig)

All 161 blob vectors covered. 3 textual assertions are N/A.

- [x] Type table: empty, unused, repeated, recursive, too short, vacuous (x2)
- [x] Type table: entry out of range, arg out of range, arg too short/long
- [x] Type table: non-primitive in arg, primitive in table, principal in table
- [x] Type table: table entry in table, self-reference, too long
- [x] opt: null, type out of range, 42, out of range (x2), too short, too long
- [x] opt: nested, recursion, non-recursive, mutual recursion, extra arg
- [x] opt parsing: null/false/true at opt bool, invalid bool, extra value
- [x] opt parsing: null/opt null/opt opt false at opt opt bool
- [x] opt parsing: false/true at opt bool (subtype coercion)
- [x] opt parsing: null at opt opt null, true at opt opt bool
- [x] opt parsing: recursive opt (Opt type)
- [x] opt parsing: fix record at fix record opt fails
- [x] opt coercion: reserved <: opt nat, null/opt bool <: opt nat
- [x] opt coercion: invalid boolean, opt opt bool <: opt nat/opt opt nat
- [x] opt: recovered coercion error under variant
- [x] missing optional/reserved record field
- [x] vec: empty, non subtype empty, two elements, blob, null, null <: vec opt nat
- [x] vec: too short (count/element), too long
- [x] vec: recursive vector, tree, non-recursive tree, vec of records/empty records
- [N/A] vec: type mismatch (textual)
- [x] record: empty, multiple, value, opt, reserved, ignore fields
- [N/A] record: ignore fields (textual)
- [x] record: missing field, missing opt field, missing null field
- [x] record: tuple, ignore fields from tuple, type mismatch, duplicate, unsorted
- [x] record: named fields, unicode field, field hash larger than u32, nested
- [x] record: empty recursion, value too short/long, type too short (x2)/long
- [x] record: type out of range (x2)
- [N/A] variant: no empty value (textual)
- [x] variant: no empty value (blob), numbered field, type mismatch (x2)
- [x] variant: ignore field, {0;1} <: variant {0}, {0;1} <: opt variant {0}
- [x] variant: change index, missing field, index out of range
- [x] variant: duplicate fields (x2), unsorted, ok/unsorted with maxInt
- [x] variant: enum, unicode field, result, with empty, with EmptyRecord
- [x] variant: empty recursion, field hash larger than u32
- [x] variant: value too short/long, type out of range/too short/too long
- [x] record/variant: empty/non-empty list, reorder type table, mutual recursive
- [x] variant: extra args, non-null extra args
- [x] skip fields (x3), new variant/record field
- [x] reserved: basic, as null, (reserved,reserved) as (null,null)
- [x] reserved: (reserved,5) as (null,nat), record/variant with reserved field
- [x] reserved: vector with reserved, optional reserved
- [x] parsing nat as null fails
- [x] empty/non-empty tuple into longer tuple
- [x] record with expected field greater/less than wire field
- [x] future type: minimal, with data

## reference.test.did (reference.zig)

All 42 blob vectors covered. 1 textual assertion is N/A.

- [x] principal: ic0, 3 bytes, 9 bytes, anonymous
- [x] principal: different bytes (!=), no tag, too short, too long, not construct
- [x] service: not principal, not primitive type
- [N/A] service: not principal (textual)
- [x] service: basic (x2), with methods, with two methods
- [x] service: too long, too short, unsorted, unsorted (but sorted by hash)
- [x] service: invalid unicode, duplicate
- [x] service: unicode
- [x] service { foo: principal }, service { foo: opt bool } (x2)
- [x] func: basic (quote name / non-quote name use same blob)
- [x] func: wrong tag, unicode, with args, query, composite query
- [x] func: unknown annotation, not primitive, no tag
- [x] func: service not in type table, invalid annotation
- [x] service {} !<: service { foo : (text) -> (nat) }
- [x] service { foo query } !<: service { foo }
- [x] service { foo } !<: service { foo query }
- [x] service { foo } decodes at service {}
- [x] func () -> () !<: func (text) -> (nat)
- [x] func (text) -> (nat) decodes at func (text, opt text) -> ()

## overshoot.test.did (overshoot.zig)

All 10 vectors covered.

- [x] type table length
- [x] argument sequence length
- [x] text length
- [x] principal length
- [x] record field number
- [x] variant field number
- [x] vector length
- [x] func arg length
- [x] future type length
- [x] future value length

## spacebomb.test.did (spacebomb.zig)

All 17 vectors covered.

- [x] vec null (extra argument)
- [x] vec reserved (extra argument)
- [x] zero-sized record (extra argument)
- [x] vec vec null (extra argument)
- [x] vec record {} (extra argument)
- [x] vec opt record with 2^20 null (extra argument)
- [x] vec null (not ignored)
- [x] vec reserved (not ignored)
- [x] zero-sized record (not ignored)
- [x] vec vec null (not ignored)
- [x] vec record {} (not ignored)
- [x] vec null (subtyping)
- [x] vec reserved (subtyping)
- [x] zero-sized record (subtyping)
- [x] vec vec null (subtyping)
- [x] vec record {} (subtyping)
- [x] vec opt record with 2^20 null (subtyping)

## subtypes.test.did (subtypes.zig)

All 57 active vectors covered. 1 upstream-commented vector also commented here.

- [x] null <: null, bool <: bool, nat <: nat, int <: int
- [x] nat <: int, null </: nat, nat </: nat8, nat8 </: nat
- [x] nat <: opt bool, opt bool <: opt bool, bool <: opt bool
- [x] mu opt <: opt opt nat
- [x] record {} <: record {}
- [x] record {} <: record { a : opt empty / opt null / reserved / null }
- [x] record {} </: record { a : empty / nat }
- [x] func () -> () <: func () -> ()
- [x] func () -> () <: func () -> (opt empty / opt null / reserved / null)
- [x] func () -> () </: func () -> (empty / nat)
- [x] func (opt empty / opt null / reserved / null) -> () <: func () -> ()
- [x] func (empty / nat) -> () </: func () -> ()
- [x] variant {} <: variant {} / variant {0 : nat}
- [x] variant {0 : nat} <: variant {0 : nat}
- [x] variant {0 : bool} </: variant {0 : nat} / variant {1 : bool}
- [x] (mu record) <: (mu record), record {mu record}, (mu (record opt))
- [x] empty <: (mu record), record {mu record} <: (mu record)
- [ ] (mu record) </: empty (commented out upstream)
- [x] (mu variant) <: (mu variant), variant {mu variant}
- [x] (mu variant) </: empty, empty <: (mu variant)
- [x] variant {mu variant} <: (mu variant)
- [x] (mu vec) <: (mu vec), vec {mu vec}
- [x] (mu vec) </: empty, empty <: (mu vec)
- [x] vec {mu vec} <: (mu vec)
- [x] (future type) <: (opt empty)
- [x] (future type) </: (nat)
