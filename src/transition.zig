//! Inter-canister calls with no hidden commit points.
//!
//! Performing a call and returning to the system commits canister state. The
//! continuation runs as a separate message, against state that may have
//! changed, with no `msg_caller`. So a call names its continuation up front
//! and yields a `Transition`, which the calling function must return. Nothing
//! can follow it, and nothing is carried across the commit.

const std = @import("std");
const ic0 = @import("ic0.zig");

const allocator = @import("allocator.zig").default;

pub const Error = error{CallPerformFailed};

/// How a message execution ended.
pub const Transition = enum(u8) {
    replied,
    rejected,
    sent,
};

pub const Rejection = struct {
    code: u32,
    message: []const u8,
};

/// Wire format for a call's argument and reply. Any format works, Candid,
/// CBOR, protobuf, as long as it provides these two:
///
///     fn encode(comptime T: type, value: T) []const u8
///     fn decode(comptime T: type, bytes: []const u8) T
pub const Raw = struct {
    pub fn encode(comptime _: type, value: []const u8) []const u8 {
        return value;
    }

    pub fn decode(comptime _: type, bytes: []const u8) []const u8 {
        return bytes;
    }
};

pub fn replyRaw(payload: []const u8) Transition {
    if (payload.len != 0) {
        ic0.msg_reply_data_append(payload.ptr, @intCast(payload.len));
    }
    ic0.msg_reply();
    return .replied;
}

/// Reply with a value encoded by the canister's `cdk_codec`, the same format
/// entry point arguments are decoded with.
pub fn reply(value: anytype) Transition {
    // Imported here rather than at the top because export.zig imports this
    // file for its default codec.
    const codec = @import("export.zig").codec;
    return replyRaw(codec.encode(@TypeOf(value), value));
}

/// Reply with a value in a format other than the canister's `cdk_codec`.
pub fn replyWith(comptime Codec: type, value: anytype) Transition {
    return replyRaw(Codec.encode(@TypeOf(value), value));
}

pub fn reject(message: []const u8) Transition {
    ic0.msg_reject(message.ptr, @intCast(message.len));
    return .rejected;
}

/// Default `onReject`, passes the callee's reject message on to our caller.
pub fn forwardReject(rejection: Rejection) Transition {
    return reject(rejection.message);
}

pub fn call(callee: []const u8, method: []const u8) Call(Raw) {
    return .{ .callee = callee, .method = method };
}

pub fn callWith(comptime Codec: type, callee: []const u8, method: []const u8) Call(Codec) {
    return .{ .callee = callee, .method = method };
}

pub fn Call(comptime Codec: type) type {
    return struct {
        callee: []const u8,
        method: []const u8,
        payload: []const u8 = &.{},
        cycles: u128 = 0,
        timeout_seconds: ?u32 = null,

        const Self = @This();

        pub fn arg(self: Self, value: anytype) Self {
            var next = self;
            next.payload = Codec.encode(@TypeOf(value), value);
            return next;
        }

        pub fn withCycles(self: Self, amount: u128) Self {
            var next = self;
            next.cycles = amount;
            return next;
        }

        pub fn withTimeout(self: Self, seconds: u32) Self {
            var next = self;
            next.timeout_seconds = seconds;
            return next;
        }

        /// Send the call and end this message. The continuations are named
        /// here because there is no way to resume at the next statement:
        ///
        ///     .commit(.{ .onReply = replied })
        ///     .commit(.{ .onReply = replied, .onReject = rejected })
        ///
        /// `onReject` defaults to `forwardReject`.
        ///
        /// Nothing is passed to them. State they need must be re-read from
        /// the canister, since the commit means it may have moved underneath.
        pub fn commit(self: Self, comptime continuations: anytype) Error!Transition {
            const C = @TypeOf(continuations);
            const onReject = if (@hasField(C, "onReject"))
                continuations.onReject
            else
                forwardReject;
            const handlers = Handlers(Codec, continuations.onReply, onReject);

            ic0.call_new(
                self.callee.ptr,
                @intCast(self.callee.len),
                self.method.ptr,
                @intCast(self.method.len),
                funcIdx(handlers.replyCallback),
                0,
                funcIdx(handlers.rejectCallback),
                0,
            );

            if (self.payload.len > 0) {
                ic0.call_data_append(self.payload.ptr, @intCast(self.payload.len));
            }
            if (self.cycles > 0) {
                const high: i64 = @bitCast(@as(u64, @truncate(self.cycles >> 64)));
                const low: i64 = @bitCast(@as(u64, @truncate(self.cycles)));
                ic0.call_cycles_add128(high, low);
            }
            if (self.timeout_seconds) |seconds| {
                ic0.call_with_best_effort_response(@intCast(seconds));
            }

            if (ic0.call_perform() != 0) return Error.CallPerformFailed;
            return .sent;
        }
    };
}

fn replyType(comptime onReply: anytype) type {
    const info = @typeInfo(@TypeOf(onReply));
    if (info != .@"fn") @compileError("onReply must be a function");
    if (info.@"fn".param_types.len != 1)
        @compileError("onReply must take exactly one parameter, the decoded reply");
    if (info.@"fn".return_type != Transition)
        @compileError("onReply must return Transition");
    return info.@"fn".param_types[0] orelse
        @compileError("onReply may not take a generic parameter");
}

// The env word is unused. A continuation is a static function, so its table
// index identifies it completely and there is no per-call state to keep.
fn Handlers(
    comptime Codec: type,
    comptime onReply: anytype,
    comptime onReject: fn (Rejection) Transition,
) type {
    const Reply = replyType(onReply);

    return struct {
        fn replyCallback(_: ic0.I) callconv(.c) void {
            const size: usize = @intCast(ic0.msg_arg_data_size());
            const data = allocator.alloc(u8, size) catch
                @panic("failed to allocate reply data");
            defer allocator.free(data);
            if (size > 0) ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));
            _ = onReply(Codec.decode(Reply, data));
        }

        fn rejectCallback(_: ic0.I) callconv(.c) void {
            const size: usize = @intCast(ic0.msg_reject_msg_size());
            const message = allocator.alloc(u8, size) catch
                @panic("failed to allocate reject message");
            defer allocator.free(message);
            if (size > 0) ic0.msg_reject_msg_copy(message.ptr, 0, @intCast(size));
            _ = onReject(.{
                .code = @intCast(ic0.msg_reject_code()),
                .message = message,
            });
        }
    };
}

fn funcIdx(comptime f: anytype) ic0.I {
    return @intCast(@intFromPtr(&f));
}
