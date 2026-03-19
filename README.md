# Zig CDK

A Zig canister development kit for the [Internet Computer](https://internetcomputer.org/).

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
    _ = cdk.addCanister(b, dep, "my_canister");
    _ = cdk.addTests(b, dep);
}
```

Write your canister in `my_canister.zig`:

```zig
const cdk = @import("cdk");

var counter: u32 = 0;

fn increment() void {
    counter += 1;
    cdk.replyRaw(&std.mem.toBytes(counter));
}

fn getCounter() void {
    cdk.replyRaw(&std.mem.toBytes(counter));
}

const std = @import("std");

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

Declare canister methods with comptime decorators:

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

### Timers

Schedule one-shot and repeating timers:

```zig
const cdk = @import("cdk");

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

Make calls to other canisters with typed futures:

```zig
const cdk = @import("cdk");

fn callOther() void {
    const callee = cdk.principal.comptimeEncode("aaaaa-aa");
    var future = cdk.call.CallFuture(.raw, void).init(callee, "some_method");
    future.setArg("hello");
    future.onReply(struct {
        fn f() void {
            cdk.replyRaw(cdk.argData());
        }
    }.f);
    future.enqueue() catch cdk.trap("call failed");
}
```

### Stable memory

Persist data across upgrades with raw or streaming APIs:

```zig
const cdk = @import("cdk");

var counter: u64 = 0;

fn save() void {
    cdk.stableGrow(1);
    cdk.stableWrite(0, &std.mem.toBytes(counter));
}

fn restore() void {
    var buf: [8]u8 = undefined;
    cdk.stableRead(0, &buf);
    counter = std.mem.bytesToValue(u64, &buf);
}
```

The `cdk.stable` module also provides streaming `Writer` and `Reader` types
that handle page allocation automatically.

### Async executor

For complex multi-step call sequences, use poll-based state machines instead
of nested callbacks:

```zig
const cdk = @import("cdk");

const MyTask = struct {
    state: enum { init, waiting, done } = .init,

    fn poll(self: *MyTask, waker: cdk.executor.Waker) cdk.executor.PollResult {
        switch (self.state) {
            .init => {
                var future = cdk.call.CallFuture(.raw, void).init(callee, "greet");
                future.onWake(waker);
                future.enqueue() catch return .ready;
                self.state = .waiting;
                return .pending;
            },
            .waiting => {
                cdk.replyRaw(cdk.argData());
                self.state = .done;
                return .ready;
            },
            .done => return .ready,
        }
    }
};
```

### Profiling

Enable compile-time profiling with zero overhead when disabled:

```zig
pub const cdk_profiling = true;
```

This automatically instruments all entry points and exposes profiling
endpoints for fetching trace data. Generate flamegraphs from PocketIC tests
to visualize instruction costs, heap growth, and stable memory usage.

See [examples/profiling/](examples/profiling/) for details.

## Build helpers

The CDK provides two build-system functions importable via `@import("cdk")`:

- **`addCanister(b, dep, name)`** -- builds a
  `wasm32-freestanding` canister from `{name}.zig`, with `ReleaseSmall`
  optimization, entry disabled, and rdynamic enabled. Returns the
  `*Compile` step for further customization.

- **`addTests(b, dep)`** -- sets up an e2e test step that compiles
  `test.zig` with the `pocket-ic` module and depends on the install step.
  Returns the `*Run` step for chaining additional steps.

## Examples

| Example | Description |
|---------|-------------|
| [call](examples/call/) | Inter-canister calls with callback-based futures |
| [executor](examples/executor/) | Async task executor with poll-based state machines |
| [timers](examples/timers/) | One-shot and repeating timer scheduling |
| [stable](examples/stable/) | Stable memory persistence across upgrades |
| [profiling](examples/profiling/) | Instruction profiling and flamegraph generation |

## Development

```
zig build test     # run unit tests
zig build e2e      # run all example e2e tests
```
