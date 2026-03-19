const std = @import("std");
const ic0 = @import("ic0.zig");
const allocator = @import("allocator.zig").default;

pub const TimerId = u64;

const Timer = struct {
    deadline: u64,
    callback: *const fn () void,
    interval: ?u64,
};

var next_id: TimerId = 0;
var map: std.AutoArrayHashMapUnmanaged(TimerId, Timer) = .{};

pub fn setTimer(delay_nanos: u64, callback: *const fn () void) TimerId {
    return addTimer(delay_nanos, callback, null);
}

pub fn setTimerInterval(interval_nanos: u64, callback: *const fn () void) TimerId {
    return addTimer(interval_nanos, callback, interval_nanos);
}

pub fn cancelTimer(id: TimerId) void {
    _ = map.swapRemove(id);
    updateIcTimer();
}

pub fn cancelAll() void {
    map.clearAndFree(allocator);
    _ = ic0.global_timer_set(0);
}

// Process all expired timers. Call this from canister_global_timer:
//
//   const cdk = @import("cdk");
//   comptime {
//       cdk.globalTimer(cdk.timers.processTimers);
//   }
//
pub fn processTimers() void {
    const now: u64 = @intCast(ic0.time());

    // Collect expired timer IDs to avoid modifying the map during iteration.
    var expired = std.ArrayListUnmanaged(TimerId){};
    defer expired.deinit(allocator);

    for (map.keys(), map.values()) |id, t| {
        if (t.deadline <= now) {
            expired.append(allocator, id) catch
                @panic("failed to allocate expired timer list");
        }
    }

    for (expired.items) |id| {
        // Entry may have been cancelled by a prior callback in this batch.
        const entry = map.get(id) orelse continue;
        const callback = entry.callback;

        if (entry.interval) |interval| {
            // Reschedule before invoking so the callback can cancel if needed.
            map.put(allocator, id, .{
                .deadline = entry.deadline +| interval,
                .callback = callback,
                .interval = entry.interval,
            }) catch @panic("failed to reschedule timer");
        } else {
            _ = map.swapRemove(id);
        }

        callback();
    }

    updateIcTimer();
}

fn addTimer(delay: u64, callback: *const fn () void, interval: ?u64) TimerId {
    const now: u64 = @intCast(ic0.time());
    const id = next_id;
    next_id += 1;

    map.put(allocator, id, .{
        .deadline = now +| delay,
        .callback = callback,
        .interval = interval,
    }) catch @panic("failed to allocate timer");

    updateIcTimer();
    return id;
}

fn updateIcTimer() void {
    var min_deadline: u64 = std.math.maxInt(u64);
    var found = false;
    for (map.values()) |t| {
        if (t.deadline < min_deadline) {
            min_deadline = t.deadline;
            found = true;
        }
    }
    if (found) {
        _ = ic0.global_timer_set(@intCast(min_deadline));
    } else {
        _ = ic0.global_timer_set(0);
    }
}
