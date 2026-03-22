# Candid

A Zig implementation of the [Candid](https://github.com/dfinity/candid) binary
encoding, the standard interface description language for the
[Internet Computer](https://internetcomputer.org/).

## Usage

Import via the CDK:

```zig
const candid = @import("cdk").candid;
```

### Encoding

Pass a tuple of values to `encode`:

```zig
const allocator = std.heap.page_allocator;

// Encode a single value.
const bytes = try candid.encode(allocator, .{@as(u32, 42)});

// Encode multiple arguments.
const bytes2 = try candid.encode(allocator, .{true, @as(u32, 42), "hello"});

// Pre-computed constant for calls with no arguments.
const empty = candid.empty_args; // "DIDL\x00\x00"
```

### Decoding

Decode a single value with `decode`, or a tuple with `decodeMany`:

```zig
const value = try candid.decode(u32, allocator, bytes);

const args = try candid.decodeMany(struct { bool, u32, []const u8 }, allocator, bytes2);
// args[0] == true, args[1] == 42, args[2] == "hello"
```

Use `decodeAdvanced`/`decodeManyAdvanced` to configure decoder limits:

```zig
const result = try candid.decodeAdvanced(u32, allocator, bytes, .{
    .max_zero_sized_vec_len = 10_000, // space bomb protection (default: 1_000_000)
});
```

## Type mapping

| Candid type | Zig type |
|---|---|
| `null` | `void` |
| `bool` | `bool` |
| `nat` | `u128` |
| `int` | `i128` |
| `nat8`..`nat64` | `u8`..`u64` |
| `int8`..`int64` | `i8`..`i64` |
| `float32` | `f32` |
| `float64` | `f64` |
| `text` | `[]const u8` |
| `blob` | `candid.Blob` |
| `opt T` | `?T` |
| `vec T` | `[]T` |
| `record { ... }` | `struct { ... }` |
| `variant { ... }` | `union(enum) { ... }` |
| `principal` | `candid.Principal` |
| `service` | `candid.Service` |
| `func` | `candid.Func` |
| `reserved` | `candid.Reserved` |
| `empty` | `candid.Empty` |

### Records and variants

Struct and union field names are hashed at compile time to produce Candid field
IDs, matching the Candid specification's label hashing. Fields are automatically
sorted by hash for correct wire order.

```zig
// record { name : text; age : nat32 }
const Person = struct {
    name: []const u8,
    age: u32,
};

// variant { ok : nat32; err : text }
const Result = union(enum) {
    ok: u32,
    err: []const u8,
};
```

### Functions and services

Use `FuncType` with an annotation to declare typed function references:

```zig
const MyQuery = candid.FuncType(.query);
// Shorthand aliases: candid.QueryFunc, candid.OnewayFunc, candid.CompositeQueryFunc
```

## Conformance

The decoder is tested against 455+ vectors from the
[dfinity/candid reference test suite](https://github.com/dfinity/candid/tree/master/test),
covering primitives, composite types, references, buffer overshoots, space bombs,
and subtype coercion. See [conformance/COVERAGE.md](conformance/COVERAGE.md) for
the full checklist.
