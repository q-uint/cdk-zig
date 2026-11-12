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
const ic0_spec = @import("ic0_spec.zig");
const root = @import("root");

const allocator = @import("allocator.zig").default;

pub const Raw = codec.Raw;

pub const Error = error{
    CallPerformFailed,
    TooManyCallsInFlight,
};

const options = if (@hasDecl(root, "cdk_options")) root.cdk_options else struct {};

/// How many calls carrying pending state may be in flight per call site.
/// Storage is static, so each such call site costs `capacity` slots of its
/// own pending type. Override per call with `.capacity`.
pub const default_capacity: u16 = if (@hasDecl(options, "call_capacity"))
    options.call_capacity
else
    64;

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

var call_performed: bool = false;

fn beginMessage() void {
    call_performed = false;
}

// A message that sent a call must end by returning that call's Transition,
// or its continuation will arrive and respond a second time.
fn checkOutcome(outcome: ?Transition) void {
    if (!call_performed) return;
    const settled = outcome orelse
        trap("cdk: an entry point returning void sent a call, it must return a Transition");
    if (settled != .sent)
        trap("cdk: a call was sent but its Transition was not returned");
}

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

// The default has to match onReply's arity, so it is generated against the
// pending type rather than written once.
fn defaultReject(comptime Pending: type) if (Pending == void)
    fn (Rejection) Transition
else
    fn (Pending, Rejection) Transition {
    if (Pending == void) return forwardReject;
    return struct {
        fn f(_: Pending, rejection: Rejection) Transition {
            return reject(rejection.message);
        }
    }.f;
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
/// A continuation borrows its reply or rejection for the duration of the
/// call. The buffer is freed when it returns, so anything kept beyond that
/// must be copied.
///
/// `request` is runtime:
///
///     .callee    .method    .arg    .cycles    .timeout_seconds
pub fn commit(comptime spec: anytype, request: anytype) Error!Transition {
    comptime checkFields(@TypeOf(spec), &.{
        "codec", "onReply", "onReject", "onFinish", "capacity",
    });
    comptime checkFields(@TypeOf(request), &.{
        "callee", "method", "arg", "pending", "cycles", "timeout_seconds",
    });

    const Spec = @TypeOf(spec);
    const Request = @TypeOf(request);
    const Codec = if (@hasField(Spec, "codec")) spec.codec else codec.default;
    const capacity = if (@hasField(Spec, "capacity")) spec.capacity else default_capacity;
    const onReject = if (@hasField(Spec, "onReject"))
        spec.onReject
    else
        defaultReject(shapeOf(spec.onReply, "onReply").Pending);

    const onFinish = if (@hasField(Spec, "onFinish")) spec.onFinish else null;
    const handlers = Handlers(Codec, spec.onReply, onReject, onFinish, capacity);

    if (handlers.carries_pending != @hasField(Request, "pending")) {
        @compileError(if (handlers.carries_pending)
            "onReply takes pending state, so the request needs a .pending field"
        else
            "onReply takes no pending state, so .pending has nowhere to go");
    }

    const env: ic0.I = if (comptime handlers.carries_pending)
        try handlers.put(request.pending)
    else
        0;
    errdefer handlers.discard(env);

    var callee = request.callee;

    ic0.call_new(
        callee.slice().ptr,
        @intCast(callee.len),
        request.method.ptr,
        @intCast(request.method.len),
        funcIdx(handlers.replyCallback),
        env,
        funcIdx(handlers.rejectCallback),
        env,
    );

    if (handlers.carries_pending) {
        ic0.call_on_cleanup(funcIdx(handlers.cleanupCallback), env);
    }

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
    call_performed = true;
    return .sent;
}

const Shape = struct {
    /// Pending state the continuation is handed back, `void` when it takes
    /// none.
    Pending: type,
    /// The decoded reply, or `Rejection`.
    Payload: type,

    fn carriesPending(self: Shape) bool {
        return self.Pending != void;
    }
};

fn shapeOf(comptime handler: anytype, comptime name: []const u8) Shape {
    const info = @typeInfo(@TypeOf(handler));
    if (info != .@"fn") @compileError(name ++ " must be a function");

    const f = info.@"fn";
    if (f.return_type != Transition) @compileError(name ++ " must return Transition");

    const generic = name ++ " may not take a generic parameter";
    return switch (f.param_types.len) {
        1 => .{ .Pending = void, .Payload = f.param_types[0] orelse @compileError(generic) },
        2 => .{
            .Pending = f.param_types[0] orelse @compileError(generic),
            .Payload = f.param_types[1] orelse @compileError(generic),
        },
        else => @compileError(name ++ " takes the reply, optionally preceded by pending state"),
    };
}

// Pending state lives in a fixed array inside this type, which is generated
// per call site. The env word handed to ic0 is an index into it rather than a
// pointer, so a callback arriving after an upgrade finds a zeroed slot and
// traps deliberately instead of reading whatever now occupies that address.
fn Handlers(
    comptime Codec: type,
    comptime onReply: anytype,
    comptime onReject: anytype,
    comptime onFinish: anytype,
    comptime capacity: u16,
) type {
    const shape = shapeOf(onReply, "onReply");
    const Reply = shape.Payload;
    const Pending = shape.Pending;

    const reject_shape = shapeOf(onReject, "onReject");
    if (reject_shape.Payload != Rejection)
        @compileError("onReject's last parameter must be Rejection");
    if (reject_shape.Pending != Pending)
        @compileError("onReply and onReject must agree on the pending state type");

    return struct {
        const carries_pending = shape.carriesPending();
        const slot_count = if (carries_pending) capacity else 0;
        var slots: [slot_count]?Pending = @splat(null);

        fn put(value: Pending) Error!ic0.I {
            for (&slots, 0..) |*slot, index| {
                if (slot.* != null) continue;
                slot.* = value;
                return @intCast(index);
            }
            return Error.TooManyCallsInFlight;
        }

        fn take(env: ic0.I) Pending {
            if (comptime !carries_pending) return {};
            const index: usize = @intCast(env);
            if (index >= slots.len) trap("cdk: callback slot out of range");
            const value = slots[index] orelse
                trap("cdk: callback for a released slot, upgraded mid-call?");
            slots[index] = null;
            return value;
        }

        // Pending state that declares a deinit owns something, so it is run
        // on every exit: reply, reject, and the cleanup callback. Cleanup is
        // the one canister code cannot reach, since only the CDK registers
        // call_on_cleanup.
        fn finish(value: Pending) void {
            if (comptime !carries_pending) return;
            if (comptime @TypeOf(onFinish) != @TypeOf(null)) onFinish(value);
        }

        // Used by the cleanup callback and by commit when the call never
        // leaves. The slot is still occupied in both cases, so whatever it
        // holds is finished here rather than dropped.
        fn discard(env: ic0.I) void {
            if (comptime !carries_pending) return;
            const index: usize = @intCast(env);
            if (index >= slots.len) return;
            if (slots[index]) |value| {
                slots[index] = null;
                finish(value);
            }
        }

        fn replyCallback(env: ic0.I) callconv(.c) void {
            beginMessage();
            const pending = take(env);
            const size: usize = @intCast(ic0.msg_arg_data_size());
            const data = allocator.alloc(u8, size) catch
                @panic("failed to allocate reply data");
            defer allocator.free(data);
            if (size > 0) ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));

            const decoded = Codec.decode(Reply, data);
            if (comptime carries_pending) {
                defer finish(pending);
                checkOutcome(onReply(pending, decoded));
            } else {
                checkOutcome(onReply(decoded));
            }
        }

        fn rejectCallback(env: ic0.I) callconv(.c) void {
            beginMessage();
            const pending = take(env);
            const size: usize = @intCast(ic0.msg_reject_msg_size());
            const message = allocator.alloc(u8, size) catch
                @panic("failed to allocate reject message");
            defer allocator.free(message);
            if (size > 0) ic0.msg_reject_msg_copy(message.ptr, 0, @intCast(size));

            const rejection = Rejection{
                .code = @intCast(ic0.msg_reject_code()),
                .message = message,
            };
            if (comptime carries_pending) {
                defer finish(pending);
                checkOutcome(onReject(pending, rejection));
            } else {
                checkOutcome(onReject(rejection));
            }
        }

        // Runs when a callback traps or the call context is deleted, the only
        // cases where neither callback runs. Replying is not permitted here,
        // so releasing the slot is all it can do.
        fn cleanupCallback(env: ic0.I) callconv(.c) void {
            discard(env);
        }
    };
}

/// Wraps a canister entry point into the shape the system API expects. The
/// handler may take the decoded message argument and may return a Transition
/// stating how the message ended; the system wants neither.
pub fn entryPoint(comptime func: anytype, comptime context: ic0.Context) fn () void {
    const info = @typeInfo(@TypeOf(func)).@"fn";

    if (info.param_types.len == 0) {
        return struct {
            fn f() void {
                beginMessage();
                checkOutcome(outcomeOf(func, .{}));
            }
        }.f;
    }

    if (info.param_types.len != 1)
        @compileError("an entry point takes at most one parameter, the decoded argument");

    // Reading the argument means calling msg_arg_data, which the spec does
    // not permit from every entry point. A pre_upgrade or timer handler has
    // no argument to read and would trap at runtime.
    if (!ic0_spec.allows("msg_arg_data_size", context))
        @compileError("this entry point runs in a context with no message argument, " ++
            "so its handler cannot take one");

    const Arg = info.param_types[0] orelse
        @compileError("an entry point may not take a generic parameter");

    return struct {
        fn f() void {
            beginMessage();
            const size: usize = @intCast(ic0.msg_arg_data_size());
            const data = allocator.alloc(u8, size) catch
                @panic("failed to allocate argument data");
            defer allocator.free(data);
            if (size > 0) ic0.msg_arg_data_copy(data.ptr, 0, @intCast(size));

            checkOutcome(outcomeOf(func, .{codec.default.decode(Arg, data)}));
        }
    }.f;
}

// Null stands for an entry point returning void, which checkOutcome reads as
// one that cannot state an outcome.
fn outcomeOf(comptime func: anytype, args: anytype) ?Transition {
    if (comptime @typeInfo(@TypeOf(func)).@"fn".return_type == void) {
        @call(.auto, func, args);
        return null;
    }
    return @call(.auto, func, args);
}

fn trap(message: []const u8) noreturn {
    ic0.trap(message.ptr, @intCast(message.len));
    unreachable;
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
