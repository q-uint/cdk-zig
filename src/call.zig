const std = @import("std");
const ic0 = @import("ic0.zig");

const allocator = @import("allocator.zig").default;

pub const CallError = error{
    CallPerformFailed,
};

pub const Rejection = struct {
    code: i32,
    message: []const u8,

    pub fn isCleanReject(self: Rejection) bool {
        return switch (self.code) {
            1, 2, 3 => true, // sysFatal, sysTransient, destinationInvalid
            else => false,
        };
    }

    pub fn isImmediatelyRetryable(self: Rejection) bool {
        return switch (self.code) {
            2, 6 => true, // sysTransient, sysUnknown
            else => false,
        };
    }
};

pub const CallOptions = struct {
    cycles: u128 = 0,
    timeout_seconds: ?u32 = null,
};

pub const RawCodec = struct {
    pub fn encode(comptime _: type, value: anytype) []const u8 {
        return value;
    }

    pub fn decode(comptime _: type, bytes: []const u8) []const u8 {
        return bytes;
    }
};

pub const CallFuture = TypedCallFuture(RawCodec, []const u8);

// A future representing an in-flight inter-canister call.
//
// The IC's execution model is callback-based: after call_perform,
// the current handler returns and the IC invokes the reply/reject
// callback in a new execution context. The future manages the
// shared state between the setup and callback phases.
//
// Parameterized by a Codec that handles serialization. The Codec
// must provide:
//   fn encode(comptime T: type, value: T) []const u8
//   fn decode(comptime T: type, bytes: []const u8) T
//
// Usage with raw bytes (via CallFuture = TypedCallFuture(RawCodec, []const u8)):
//
//   const future = try CallFuture.call("aaaaa-aa", "method", args);
//   future.onReply(struct {
//       fn f(result: CallFuture.Result) void {
//           switch (result) {
//               .reply => |data| cdk.replyRaw(data),
//               .reject => |r| cdk.trap(r.message),
//           }
//       }
//   }.f);
//
// Usage with typed encoding:
//
//   const Future = TypedCallFuture(MyCandid, MyReturnType);
//   const future = try Future.call("aaaaa-aa", "method", my_args);
//   future.onReply(struct {
//       fn f(result: Future.Result) void {
//           switch (result) {
//               .reply => |val| { ... }, // val is MyReturnType
//               .reject => |r| cdk.trap(r.message),
//           }
//       }
//   }.f);
//
pub fn TypedCallFuture(comptime Codec: type, comptime Return: type) type {
    return struct {
        state: *State,

        const Self = @This();

        pub const Result = union(enum) {
            reply: Return,
            reject: Rejection,
        };

        const Callback = *const fn (Result) void;

        const State = struct {
            result: ?Result = null,
            continuation: ?Callback = null,
        };

        pub fn call(
            callee: []const u8,
            method: []const u8,
            args: anytype,
        ) CallError!Self {
            return callWithOptions(callee, method, args, .{});
        }

        pub fn callWithOptions(
            callee: []const u8,
            method: []const u8,
            args: anytype,
            options: CallOptions,
        ) CallError!Self {
            const encoded = Codec.encode(@TypeOf(args), args);

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

            if (encoded.len > 0) {
                ic0.call_data_append(encoded.ptr, @intCast(encoded.len));
            }

            if (options.cycles > 0) {
                const high: i64 = @bitCast(@as(u64, @truncate(options.cycles >> 64)));
                const low: i64 = @bitCast(@as(u64, @truncate(options.cycles)));
                ic0.call_cycles_add128(high, low);
            }

            if (options.timeout_seconds) |timeout| {
                ic0.call_with_best_effort_response(@intCast(timeout));
            }

            const rc = ic0.call_perform();
            if (rc != 0) {
                allocator.destroy(state);
                return CallError.CallPerformFailed;
            }

            return .{ .state = state };
        }

        pub fn onReply(self: Self, cont: Callback) void {
            self.state.continuation = cont;
        }

        fn replyCallback(env: i32) callconv(.c) void {
            const state: *State = @ptrFromInt(@as(u32, @intCast(env)));

            const size: u32 = @intCast(ic0.msg_arg_data_size());
            const data = allocator.alloc(u8, size) catch
                @panic("failed to allocate reply data");
            ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));

            const decoded = Codec.decode(Return, data);
            state.result = .{ .reply = decoded };

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
}

pub fn callOneway(
    callee: []const u8,
    method: []const u8,
    args: []const u8,
) CallError!void {
    return callOnewayWithOptions(callee, method, args, .{});
}

pub fn callOnewayWithOptions(
    callee: []const u8,
    method: []const u8,
    args: []const u8,
    options: CallOptions,
) CallError!void {
    ic0.call_new(
        callee.ptr,
        @intCast(callee.len),
        method.ptr,
        @intCast(method.len),
        0,
        0,
        0,
        0,
    );

    if (args.len > 0) {
        ic0.call_data_append(args.ptr, @intCast(args.len));
    }

    if (options.cycles > 0) {
        const high: i64 = @bitCast(@as(u64, @truncate(options.cycles >> 64)));
        const low: i64 = @bitCast(@as(u64, @truncate(options.cycles)));
        ic0.call_cycles_add128(high, low);
    }

    if (options.timeout_seconds) |timeout| {
        ic0.call_with_best_effort_response(@intCast(timeout));
    }

    const rc = ic0.call_perform();
    if (rc != 0) {
        return CallError.CallPerformFailed;
    }
}

// Convert a Zig function pointer to a Wasm table index (i32).
fn funcIdx(f: anytype) i32 {
    return @intCast(@intFromPtr(&f));
}
