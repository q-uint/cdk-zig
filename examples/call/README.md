# Inter-canister call example

Two canisters: `caller` makes an inter-canister call to `callee`.

## What it does

`callee` exposes a `greet` query returning `"hello from callee"`. `caller`
receives the callee's principal as its install argument, and its `call_greet`
update forwards the reply from that call on to its own caller.

## Build and test

```
zig build        # compile both canisters to wasm
zig build test   # run the e2e tests via PocketIC
```

This produces `zig-out/bin/callee.wasm` and `zig-out/bin/caller.wasm`. The test
suite boots a replica, installs both canisters, and drives the call end to end.
It is skipped when `POCKET_IC_BIN` is unset; `nix develop` sets it for you.
