# Timers Example

Demonstrates the timer module for scheduling one-shot and repeating callbacks.

## What it does

On `init`, the canister sets up:

- A **repeating timer** that increments a counter every second
- A **one-shot timer** that adds 100 to the counter after 5 seconds

The `get_counter` query returns the current counter value, and
`stop_interval` cancels the repeating timer.

## Build and test

```
zig build        # compile the canister to wasm
zig build test   # run the e2e tests via PocketIC
```
