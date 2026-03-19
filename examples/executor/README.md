# Executor Example

Demonstrates the cooperative task executor for chaining inter-canister calls
as flat state machines instead of nested callbacks.

## What it does

The **caller** canister makes two sequential calls to the **callee** canister
(`greet` and `farewell`), combines the results, and replies with
`"hello and goodbye"`.

The `ChainedCallTask` struct implements a poll-based state machine:

1. Initiate call to `greet`, return pending
2. Read greet result, initiate call to `farewell`, return pending
3. Read farewell result, combine both, reply, return ready

Compare this to the callback-based approach in `examples/call/`, where the
same logic would require nested `onReply` closures.

## Build and test

```
zig build        # compile both canisters to wasm
zig build test   # run the e2e test via PocketIC
```
