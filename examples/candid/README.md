# Candid encoding example

Two canisters demonstrating Candid-encoded arguments and replies.

## What it does

`callee` accepts a Candid-encoded `text` name and returns a
`record { greeting: text }`. `caller` makes a typed inter-canister call using
Candid encoding and forwards the result.

## Build and test

```
zig build        # compile both canisters to wasm
zig build test   # run the e2e tests via PocketIC
```

This produces `zig-out/bin/callee.wasm` and `zig-out/bin/caller.wasm`. The test
suite boots a replica, installs both canisters, and drives the call end to end.
It is skipped when `POCKET_IC_BIN` is unset; `nix develop` sets it for you.
