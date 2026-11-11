//! Inter-canister calls with no hidden commit points.
//!
//! Performing a call and returning to the system commits canister state. The
//! continuation runs as a separate message, against state that may have
//! changed, with no `msg_caller`. So a call names its continuation up front
//! and yields a `Transition`, which the calling function must return. Nothing
//! can follow it, and nothing is carried across the commit.

const std = @import("std");
const codec = @import("codec.zig");
const ic0 = @import("ic0.zig");

const allocator = @import("allocator.zig").default;

pub const Raw = codec.Raw;

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
    return replyRaw(codec.default.encode(@TypeOf(value), value));
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

/// Send a call and end this message.
///
/// `spec` is comptime, because a continuation's address is needed to name it
/// to the system:
///
///     .codec     wire format, defaults to Raw
///     .onReply   fn (Reply) Transition
///     .onReject  fn (Rejection) Transition, defaults to forwardReject
///
/// `request` is runtime:
///
///     .callee    .method    .arg    .cycles    .timeout_seconds
pub fn commit(comptime spec: anytype, request: anytype) Error!Transition {
    comptime checkFields(@TypeOf(spec), &.{ "codec", "onReply", "onReject" });
    comptime checkFields(@TypeOf(request), &.{
        "callee", "method", "arg", "cycles", "timeout_seconds",
    });

    const Spec = @TypeOf(spec);
    const Codec = if (@hasField(Spec, "codec")) spec.codec else codec.default;
    const onReject = if (@hasField(Spec, "onReject")) spec.onReject else forwardReject;
    const handlers = Handlers(Codec, spec.onReply, onReject);

    ic0.call_new(
        request.callee.ptr,
        @intCast(request.callee.len),
        request.method.ptr,
        @intCast(request.method.len),
        funcIdx(handlers.replyCallback),
        0,
        funcIdx(handlers.rejectCallback),
        0,
    );

    if (@hasField(@TypeOf(request), "arg")) {
        const payload = Codec.encode(@TypeOf(request.arg), request.arg);
        if (payload.len > 0) ic0.call_data_append(payload.ptr, @intCast(payload.len));
    }
    if (@hasField(@TypeOf(request), "cycles")) {
        const high: i64 = @bitCast(@as(u64, @truncate(request.cycles >> 64)));
        const low: i64 = @bitCast(@as(u64, @truncate(request.cycles)));
        ic0.call_cycles_add128(high, low);
    }
    if (@hasField(@TypeOf(request), "timeout_seconds")) {
        ic0.call_with_best_effort_response(@intCast(request.timeout_seconds));
    }

    if (ic0.call_perform() != 0) return Error.CallPerformFailed;
    return .sent;
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

fn checkFields(comptime T: type, comptime known: []const []const u8) void {
    for (@typeInfo(T).@"struct".field_names) |given| {
        for (known) |name| {
            if (std.mem.eql(u8, given, name)) break;
        } else @compileError("unknown field ." ++ given ++ ", expected one of " ++ joinNames(known));
    }
}

fn joinNames(comptime names: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (names, 0..) |name, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ name;
    }
    return out;
}
