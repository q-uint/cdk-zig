const std = @import("std");
const allocator = @import("allocator.zig").default;

pub const TaskId = usize;
pub const Poll = enum { pending, ready };

pub const Waker = struct {
    task_id: TaskId,

    pub fn wake(self: Waker) void {
        enqueueWakeup(self.task_id);
        pollAll();
    }
};

const ErasedTask = struct {
    poll_fn: *const fn (*anyopaque, Waker) Poll,
    deinit_fn: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

var next_id: TaskId = 0;
var tasks: std.AutoArrayHashMapUnmanaged(TaskId, ErasedTask) = .{};
var wakeups: std.ArrayListUnmanaged(TaskId) = .{};
var polling: bool = false;

// Spawn a task from a heap-allocated pointer.
//
// The pointed-to type must have:
//   fn poll(self: *T, waker: Waker) Poll
//
// Optional:
//   fn deinit(self: *T) void
//
// The executor takes ownership; the task is freed when it completes
// or is cancelled.
pub fn spawn(ptr: anytype) TaskId {
    const Ptr = @TypeOf(ptr);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("spawn expects a single-item pointer");
    }
    const T = info.pointer.child;

    const gen = struct {
        fn poll(erased: *anyopaque, waker: Waker) Poll {
            const self: *T = @ptrCast(@alignCast(erased));
            return self.poll(waker);
        }

        fn deinit(erased: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(erased));
            if (@hasDecl(T, "deinit")) {
                self.deinit();
            }
            allocator.destroy(self);
        }
    };

    const id = next_id;
    next_id += 1;

    tasks.put(allocator, id, .{
        .poll_fn = gen.poll,
        .deinit_fn = gen.deinit,
        .ctx = @ptrCast(ptr),
    }) catch @panic("failed to allocate task");

    enqueueWakeup(id);
    return id;
}

// Allocate, initialize, and spawn a task in one step.
pub fn create(comptime T: type, value: T) TaskId {
    const ptr = allocator.create(T) catch
        @panic("failed to allocate task");
    ptr.* = value;
    return spawn(ptr);
}

// Cancel a task, invoking its deinit and freeing it.
pub fn cancel(id: TaskId) void {
    if (tasks.fetchSwapRemove(id)) |kv| {
        kv.value.deinit_fn(kv.value.ctx);
    }
}

// Drain the wakeup queue and poll all ready tasks.
// Safe against re-entrant calls (e.g. from within a poll).
pub fn pollAll() void {
    if (polling) return;
    polling = true;
    defer polling = false;

    while (wakeups.items.len > 0) {
        const batch = wakeups.toOwnedSlice(allocator) catch
            @panic("failed to drain wakeup queue");
        defer allocator.free(batch);

        for (batch) |id| {
            const entry = tasks.get(id) orelse continue;
            const result = entry.poll_fn(entry.ctx, .{ .task_id = id });
            if (result == .ready) {
                if (tasks.fetchSwapRemove(id)) |kv| {
                    kv.value.deinit_fn(kv.value.ctx);
                }
            }
        }
    }
}

// Callback suitable for use with TypedCallFuture.onWake.
// Pass a TaskId as the data argument.
pub fn wakeCallback(data: usize) void {
    const waker = Waker{ .task_id = data };
    waker.wake();
}

fn enqueueWakeup(id: TaskId) void {
    wakeups.append(allocator, id) catch
        @panic("failed to queue wakeup");
}
