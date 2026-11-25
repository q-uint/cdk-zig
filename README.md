# Zig CDK

A Zig canister development kit for the [Internet Computer](https://internetcomputer.org/),
supporting both wasm32 and wasm64 targets.

> [!WARNING]
> Unreleased. Any commit may break the API, and the layout of stable structures
> too. A canister upgraded to a newer CDK may not read what an older one wrote.

## Requirements

Zig 0.17, plus a PocketIC server on `POCKET_IC_BIN` to run the e2e suites.
`nix develop` provides both.

## Quick start

Add the CDK as a dependency in your `build.zig.zon`:

```
zig fetch --save=cdk git+https://github.com/q-uint/cdk-zig
```

Create a `build.zig`:

```zig
const cdk = @import("cdk");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("cdk", .{});
    _ = cdk.addCanister(b, dep, "my_canister", .{});
    _ = cdk.addTests(b, dep);
}
```

Write your canister in `my_canister.zig`:

```zig
const cdk = @import("cdk");

var counter: u32 = 0;

fn increment() u32 {
    counter += 1;
    return counter;
}

fn getCounter() u32 {
    return counter;
}

comptime {
    cdk.update(increment, "increment");
    cdk.query(getCounter, "get_counter");
}
```

Build and test:

```
zig build          # compile to WASM
zig build test     # run e2e tests via PocketIC
```

## Features

### Entry points

```zig
comptime {
    cdk.init(myInit);
    cdk.query(myQuery, "my_query");
    cdk.update(myUpdate, "my_update");
    cdk.preUpgrade(save);
    cdk.postUpgrade(restore);
    cdk.heartbeat(onHeartbeat);
    cdk.inspectMessage(onInspect);
    cdk.globalTimer(onTimer);
    cdk.onLowWasmMemory(onLowMemory);
}
```

A handler takes the decoded argument, optionally preceded by an allocator,
and returns:

| Returns | Effect |
|---------|--------|
| `T` | reply with `T` |
| `E!T` | reply with `T`, or reject with the error's name |
| `cdk.Transition(T)` | reply, reject with any message, or send a call |
| `void` | reply with nothing, `()` in Candid |

The reply is encoded after the handler returns, so it must not point into
the handler's stack. Build it with the allocator instead, which the CDK frees
when the message ends:

```zig
fn greet(scratch: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(scratch, "hello, {s}!", .{name});
}
```

Decoded arguments live until the message ends too. Copy what you keep into
`cdk.persistent`, which is never freed for you.

### Codecs

The default codec, Raw, handles `[]const u8` and integers (little-endian).
Declare another for everything else:

```zig
pub const cdk_codec = cdk.CandidCodec;
```

Any type with these works:

```zig
fn encode(a: std.mem.Allocator, comptime T: type, value: T) ![]const u8
fn decode(a: std.mem.Allocator, comptime T: type, bytes: []const u8) !T
```

An argument that fails to decode rejects the message.
`cdk.queryWith(Codec, f, name)` and `cdk.updateWith` override the codec for
one endpoint, `.codec` for one call. See [examples/json](examples/json/).

### Timers

```zig
fn init() void {
    // Fire once after 5 seconds.
    _ = cdk.timers.setTimer(5_000_000_000, myCallback);

    // Repeat every second.
    const id = cdk.timers.setTimerInterval(1_000_000_000, tick);
    _ = id; // use to cancel later
}

comptime {
    cdk.init(init);
    cdk.globalTimer(cdk.timers.processTimers);
}
```

### Inter-canister calls

A call commits state and ends the message. The continuation runs as a
separate message, so it is named up front:

```zig
fn replied(data: []const u8) cdk.Transition([]const u8) {
    return .reply(data);
}

fn callOther() cdk.Transition([]const u8) {
    const callee = comptime cdk.principal.comptimeFromText("aaaaa-aa");
    return .commit(.{ .onReply = replied }, .{
        .callee = callee,
        .method = "some_method",
        .arg = "hello",
    });
}
```

- The first struct is comptime: `.onReply`, `.onReject` (defaults to
  forwarding the callee's rejection), `.onError` (the call could not be sent,
  defaults to rejecting), `.codec`.
- The second is the call: `.callee`, `.method`, `.arg`, `.cycles`,
  `.timeout_seconds`.
- `.reply` only takes a `T`, and every continuation returns the same
  `Transition(T)`, since it answers the same caller.
- A continuation borrows its reply, and may take an allocator first, like a
  handler.
- A reply that does not decode traps. The callee did its work though, so a
  call whose outcome matters, a transfer say, passes `.onUndecodable` to
  record it. It gets the pending state and the raw bytes.

### Carrying state across a commit

What the continuation needs is re-read from state, or travels as `.pending`:

```zig
const Transfer = struct {
    to: []const u8,
    amount: u64,

    fn deinit(self: Transfer) void {
        cdk.persistent.free(self.to);
    }
};

fn settled(pending: Transfer, block: u64) cdk.Transition(u64) {
    credit(pending.to, block);
    return .reply(block);
}

return .commit(.{
    .onReply = settled,
    .onFinish = Transfer.deinit,
}, .{
    .callee = ledger,
    .method = "transfer",
    .arg = args,
    .pending = Transfer{ .to = to, .amount = amount },
});
```

Carry intent, not observations: anything read before the call is stale by
the time the continuation runs.

The pending type is `onReply`'s first parameter. `.onFinish` runs on reply,
reject or cleanup, so owned memory is freed exactly once. `.capacity` bounds
how many such calls a call site may have in flight.

### Stable memory

```zig
var counter: u64 = 0;

fn save() void {
    _ = cdk.stableGrow(1);
    cdk.stableWrite(0, std.mem.asBytes(&counter));
}

fn restore() void {
    var buf: [8]u8 = undefined;
    cdk.stableRead(0, &buf);
    counter = std.mem.readInt(u64, &buf, .little);
}

comptime {
    cdk.preUpgrade(save);
    cdk.postUpgrade(restore);
}
```

`cdk.stable.Writer` and `Reader` stream across pages and grow memory as
needed.

### Candid encoding/decoding

With `CandidCodec` as the codec, handlers take and return Zig types:

```zig
pub const cdk_codec = cdk.CandidCodec;

const Greeting = struct { greeting: []const u8 };

fn greet(name: []const u8) Greeting {
    return .{ .greeting = name };
}
```

For direct control, `cdk.candid` has `encode`, `decode`/`freeDecoded`, and
`decodeOwned`, which returns a value with a recursive `deinit`.

Supported: `bool`, integers, floats, `[]const u8` (text), optionals, slices
(vec), structs (record), tagged unions (variant), `Principal`, `Blob`,
`Service` and func types.

### CBOR

`cdk.CborCodec` follows RFC 8949. Structs are maps keyed by field name, or by
integer as in minicbor with `cbor_keys`, which survives renames:

```zig
const Event = struct {
    at: u64,
    amount: i64,
    memo: ?[]const u8 = null,
    pub const cbor_keys = .{ .at = 0, .amount = 1, .memo = 2 };
};
```

`[]const u8` is text. Use `cbor.ByteString` or `[N]u8` for bytes.

### Profiling

```zig
_ = cdk.addCanister(b, dep, "app", .{ .profiling = true });
```

Also builds `app_profiling.wasm`, which traces every entry point and exposes
endpoints for trace data. Tests drive it with `pocket.profiler(cid)`, read
costs with `inclusive` and `exclusive`, and render flamegraphs of
instructions, heap and stable memory. Free when disabled. See
[examples/profiling](examples/profiling/).

## Build helpers

- `addCanister(b, dep, name, options)` builds `{name}.zig` to
  `wasm32-freestanding`, or wasm64 with `.{ .wasm64 = true }`. With
  `.{ .profiling = true }` it also builds `{name}_profiling.wasm`. Returns
  the plain canister's `*Compile` step.
- `.dev_access` sets who may call the `__` endpoints: `.controllers` (the
  default), `.anyone`, or `.{ .principals = ... }` in addition to the
  controllers.
- Each wasm carries a private `cdk:build` metadata section, JSON with the cdk
  version, whether it profiles, and its `dev_access`. Only controllers can
  read it.
- `addTests(b, dep)` adds a `test` step running `test.zig` against PocketIC.
  Returns the `*Run` step. `pocket.canister(Codec, id)` gives typed calls, see
  [examples/json](examples/json/test.zig).

## Examples

| Example | Description |
|---------|-------------|
| [call](examples/call/) | Inter-canister calls, chained, with pending state |
| [candid](examples/candid/) | Candid-encoded arguments and replies |
| [certified_data](examples/certified_data/) | Certified data with a hash tree |
| [json](examples/json/) | A custom JSON codec, and a Raw endpoint beside it |
| [timers](examples/timers/) | One-shot and repeating timers |
| [stable](examples/stable/) | Stable memory, raw and streaming, across upgrades |
| [profiling](examples/profiling/) | Instruction profiling and flamegraphs |

## Development

```
zig build test     # run unit tests
zig build e2e      # run the e2e tests of examples/ and tests/
```
