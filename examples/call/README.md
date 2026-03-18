# Inter-canister call example

Two canisters: `caller` makes an inter-canister call to `callee`.

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

Query the callee directly:

```sh
icp canister call callee greet --args-format hex "" -o auto
```

Make the caller call into the callee (returns "hello from callee"):

```sh
icp canister call caller call_greet --args-format hex "" -o auto
```

## Rebuild and upgrade

After changing source code, rebuild and upgrade a single canister:

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
