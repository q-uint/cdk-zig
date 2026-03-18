const std = @import("std");
const ic0 = @import("ic0.zig");

const allocator = std.heap.page_allocator;

pub const CallError = error{
    CallPerformFailed,
};

pub const CallResult = union(enum) {
    reply: []const u8,
    reject: Rejection,
};

pub const Rejection = struct {
    code: i32,
    message: []const u8,
};

// A future representing an in-flight inter-canister call.
//
// The IC's execution model is callback-based: after call_perform,
// the current handler returns and the IC invokes the reply/reject
// callback in a new execution context. CallFuture manages the
// shared state between the setup and callback phases.
//
// Usage:
//
//   const future = try CallFuture.call("aaaaa-aa", "method", args);
//   future.on_reply(struct {
//       fn f(result: CallResult) void {
//           cdk.reply_raw(result.reply);
//       }
//   }.f);
//
pub const CallFuture = struct {
    state: *State,

    const Callback = *const fn (CallResult) void;

    const State = struct {
        result: ?CallResult = null,
        continuation: ?Callback = null,
    };

    pub fn call(
        callee: []const u8,
        method: []const u8,
        args: []const u8,
    ) CallError!CallFuture {
        const state = allocator.create(State) catch
            @panic("failed to allocate CallFuture state");
        state.* = .{};

        ic0.call_new(
            callee.ptr,
            @intCast(callee.len),
            method.ptr,
            @intCast(method.len),
            funcIdx(replyCallback),
            @intCast(@intFromPtr(state)),
            funcIdx(rejectCallback),
            @intCast(@intFromPtr(state)),
        );

        if (args.len > 0) {
            ic0.call_data_append(args.ptr, @intCast(args.len));
        }

        const rc = ic0.call_perform();
        if (rc != 0) {
            allocator.destroy(state);
            return CallError.CallPerformFailed;
        }

        return .{ .state = state };
    }

    // Register a continuation to run when the call completes.
    // The continuation receives the CallResult (reply or reject).
    pub fn on_reply(self: CallFuture, cont: Callback) void {
        self.state.continuation = cont;
    }

    fn replyCallback(env: i32) callconv(.c) void {
        const state: *State = @ptrFromInt(@as(u32, @intCast(env)));

        const size: u32 = @intCast(ic0.msg_arg_data_size());
        const data = allocator.alloc(u8, size) catch
            @panic("failed to allocate reply data");
        ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));

        state.result = .{ .reply = data };

        if (state.continuation) |cont| {
            cont(state.result.?);
        }
    }

    fn rejectCallback(env: i32) callconv(.c) void {
        const state: *State = @ptrFromInt(@as(u32, @intCast(env)));

        const code = ic0.msg_reject_code();
        const msg_size: u32 = @intCast(ic0.msg_reject_msg_size());
        const msg = allocator.alloc(u8, msg_size) catch
            @panic("failed to allocate reject message");
        ic0.msg_reject_msg_copy(msg.ptr, 0, @intCast(msg_size));

        state.result = .{ .reject = .{ .code = code, .message = msg } };

        if (state.continuation) |cont| {
            cont(state.result.?);
        }
    }
};

// Convert a Zig function pointer to a Wasm table index (i32).
fn funcIdx(f: anytype) i32 {
    return @intCast(@intFromPtr(&f));
}
