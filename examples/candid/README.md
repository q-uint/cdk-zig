# Candid encoding example

Two canisters demonstrating Candid-encoded arguments and replies.

The `callee` accepts a Candid-encoded `text` name and returns a
`record { greeting: text }`. The `caller` uses `CandidCallFuture`-style
encoding to make a typed inter-canister call and forwards the result.

## Prerequisites

- Zig 0.15+
- [icp-cli](https://github.com/dfinity/icp-cli)

## Build

```sh
zig build
```

This produces `zig-out/bin/callee.wasm` and `zig-out/bin/caller.wasm`.

## Deploy

```sh
icp network start --background
icp deploy callee
CALLEE=$(icp canister status -i callee)
icp canister create caller
icp canister install caller --args-format hex --args "$(echo -n $CALLEE | xxd -p)"
```

## Test

Query the callee directly (returns `record { greeting = "hello, world!" }`):

```sh
icp canister call callee greet '("world")' -o auto
```

Make the caller call into the callee:

```sh
icp canister call caller call_greet --args-format hex "" -o auto
```

## Rebuild and upgrade

```sh
zig build callee
icp canister install callee --mode upgrade

zig build caller
icp canister install caller --mode upgrade
```

Or rebuild and upgrade everything:

```sh
icp deploy --upgrade-unchanged
```
