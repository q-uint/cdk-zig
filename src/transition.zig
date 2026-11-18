//! Inter-canister calls with no hidden commit points.
//!
//! Performing a call and returning to the system commits canister state. The
//! continuation runs as a separate message, against state that may have
//! changed, with no `msg_caller`. So a call names its continuation up front
//! and yields a `Transition`, which the calling function must return. Nothing
//! can follow it, and nothing is carried across the commit.
//!
//! `Transition(R)` puts the reply type in the signature, so the payload handed
//! to `.reply` and the continuations of every call the message sends are
//! checked against it.

const std = @import("std");
const codec = @import("codec.zig");
const ic0 = @import("ic0.zig");
const ic0_spec = @import("ic0_spec.zig");
const root = @import("root");

const memory = @import("allocator.zig");

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
pub const Outcome = enum(u8) {
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
fn checkOutcome(outcome: ?Outcome) void {
    if (!call_performed) return;
    const settled = outcome orelse
        trap("cdk: an entry point returning void sent a call, it must return a Transition");
    if (settled != .sent)
        trap("cdk: a call was sent but its Transition was not returned");
}

/// How a message that replies with `ReplyType` ended.
///
/// Handlers state their reply type in their signature, and the constructors
/// are reached through decl literals:
///
///     fn get(index: u64) tr.Transition([]const u8) {
///         if (index >= items.len) return .reject("index out of range");
///         return .reply(items[index]);
///     }
///
/// A continuation answers the caller of the message that sent the call, so
/// `commit` requires its handlers to return the same `Transition`.
pub fn Transition(comptime ReplyType: type) type {
    return struct {
        outcome: Outcome,

        const Self = @This();

        /// What this message replies with.
        pub const Reply = ReplyType;

        /// Reply with a value encoded by the canister's `cdk_codec`, the same
        /// format entry point arguments are decoded with.
        pub fn reply(value: Reply) Self {
            return replyRaw(codec.default.encode(Reply, value));
        }

        /// Reply with a value in a format other than the canister's
        /// `cdk_codec`.
        pub fn replyWith(comptime Codec: type, value: Reply) Self {
            return replyRaw(Codec.encode(Reply, value));
        }

        /// Reply with bytes as they are. Nothing checks they encode a `Reply`.
        pub fn replyRaw(payload: []const u8) Self {
            if (payload.len != 0) {
                ic0.msg_reply_data_append(payload.ptr, @intCast(payload.len));
            }
            ic0.msg_reply();
            return .{ .outcome = .replied };
        }

        pub fn reject(message: []const u8) Self {
            ic0.msg_reject(message.ptr, @intCast(message.len));
            return .{ .outcome = .rejected };
        }

        /// Default `onReject`, passes the callee's reject message on to our
        /// caller.
        pub fn forwardReject(rejection: Rejection) Self {
            return reject(rejection.message);
        }

        /// Default `onError`, rejects with a message naming the error.
        pub fn rejectError(err: Error) Self {
            return reject(switch (err) {
                Error.CallPerformFailed => "cdk: call_perform failed",
                Error.TooManyCallsInFlight => "cdk: too many calls in flight",
            });
        }

        // The default has to match onReply's arity, so it is generated
        // against the pending type rather than written once.
        fn defaultReject(comptime Pending: type) if (Pending == void)
            fn (Rejection) Self
        else
            fn (Pending, Rejection) Self {
            if (Pending == void) return forwardReject;
            return struct {
                fn f(_: Pending, rejection: Rejection) Self {
                    return reject(rejection.message);
                }
            }.f;
        }

        /// Send a call and end this message.
        ///
        /// `spec` is comptime, because a continuation's address is needed to
        /// name it to the system:
        ///
        ///     .codec     wire format, defaults to the canister's cdk_codec
        ///     .onReply   fn (Reply) Self, optionally preceded by pending state
        ///     .onReject  fn (Rejection) Self, defaults to forwardReject
        ///     .onError   fn (Error) Self, runs instead when the call is never
        ///                sent, defaults to rejectError
        ///     .onFinish  fn (Pending) void, runs on every exit
        ///     .capacity  calls carrying pending state that may be in flight
        ///
        /// Every handler returns `Self`, since it answers the caller of the
        /// message that sent the call, and may take a `std.mem.Allocator`
        /// first for memory that lasts until its message ends.
        ///
        /// A continuation borrows its reply or rejection for the duration of
        /// the call. The buffer is freed when it returns, so anything kept
        /// beyond that must be copied.
        ///
        /// `request` is runtime:
        ///
        ///     .callee    .method    .arg    .pending    .cycles
        ///     .timeout_seconds
        pub fn commit(comptime spec: anytype, request: anytype) Self {
            comptime checkFields(@TypeOf(spec), &.{
                "codec", "onReply", "onReject", "onError", "onFinish", "capacity",
            });
            const onError = if (@hasField(@TypeOf(spec), "onError")) spec.onError else rejectError;
            if (@TypeOf(onError) != fn (Error) Self and @TypeOf(onError) != fn (std.mem.Allocator, Error) Self)
                @compileError("onError must be fn (Error) " ++ @typeName(Self) ++
                    ", optionally taking an allocator first");

            send(spec, request) catch |err| return invoke(onError, .{err});
            return .{ .outcome = .sent };
        }

        fn send(comptime spec: anytype, request: anytype) Error!void {
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
                defaultReject(shapeOf(spec.onReply, "onReply", Self).Pending);

            const onFinish = if (@hasField(Spec, "onFinish")) spec.onFinish else null;
            const handlers = Handlers(Self, Codec, spec.onReply, onReject, onFinish, capacity);

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

            // A comptime-known `.callee` is a comptime field of the request
            // literal, which has no runtime address for `.ptr` to take. Any
            // comptime callee does this, not just comptimeFromText.
            const callee = request.callee;

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

            if (@hasField(Request, "arg")) {
                const payload = Codec.encode(@TypeOf(request.arg), request.arg);
                if (payload.len > 0) ic0.call_data_append(payload.ptr, @intCast(payload.len));
            }
            if (@hasField(Request, "cycles")) {
                const high: i64 = @bitCast(@as(u64, @truncate(request.cycles >> 64)));
                const low: i64 = @bitCast(@as(u64, @truncate(request.cycles)));
                ic0.call_cycles_add128(high, low);
            }
            if (@hasField(Request, "timeout_seconds")) {
                ic0.call_with_best_effort_response(@intCast(request.timeout_seconds));
            }

            if (ic0.call_perform() != 0) return Error.CallPerformFailed;
            call_performed = true;
        }
    };
}

/// Whether `T` is some `Transition(R)`.
pub fn isTransition(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Reply") and T == Transition(T.Reply);
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

fn shapeOf(comptime handler: anytype, comptime name: []const u8, comptime Returns: type) Shape {
    const info = @typeInfo(@TypeOf(handler));
    if (info != .@"fn") @compileError(name ++ " must be a function");

    const f = info.@"fn";
    if (f.return_type != Returns)
        @compileError(name ++ " must return " ++ @typeName(Returns) ++
            ", the Transition of the message that sent the call");

    const generic = name ++ " may not take a generic parameter";
    const params = f.param_types[@intFromBool(takesScratch(handler))..];
    return switch (params.len) {
        1 => .{ .Pending = void, .Payload = params[0] orelse @compileError(generic) },
        2 => .{
            .Pending = params[0] orelse @compileError(generic),
            .Payload = params[1] orelse @compileError(generic),
        },
        else => @compileError(name ++ " takes the reply, optionally preceded by " ++
            "an allocator and pending state"),
    };
}

// A handler asks for memory that lasts until the message ends by taking a
// std.mem.Allocator first. The CDK frees it all once the message ends.
fn takesScratch(comptime func: anytype) bool {
    const params = @typeInfo(@TypeOf(func)).@"fn".param_types;
    return params.len > 0 and (params[0] orelse void) == std.mem.Allocator;
}

fn invoke(comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    if (comptime takesScratch(func)) return @call(.auto, func, .{memory.scratch} ++ args);
    return @call(.auto, func, args);
}

// Pending state lives in a fixed array inside this type, which is generated
// per call site. The env word handed to ic0 is an index into it rather than a
// pointer, so a callback arriving after an upgrade finds a zeroed slot and
// traps deliberately instead of reading whatever now occupies that address.
fn Handlers(
    comptime T: type,
    comptime Codec: type,
    comptime onReply: anytype,
    comptime onReject: anytype,
    comptime onFinish: anytype,
    comptime capacity: u16,
) type {
    const shape = shapeOf(onReply, "onReply", T);
    const Reply = shape.Payload;
    const Pending = shape.Pending;

    const reject_shape = shapeOf(onReject, "onReject", T);
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
            defer memory.endMessage();
            const pending = take(env);
            const decoded = Codec.decode(Reply, readMessage(ic0.msg_arg_data_size, ic0.msg_arg_data_copy));
            if (comptime carries_pending) {
                defer finish(pending);
                checkOutcome(invoke(onReply, .{ pending, decoded }).outcome);
            } else {
                checkOutcome(invoke(onReply, .{decoded}).outcome);
            }
        }

        fn rejectCallback(env: ic0.I) callconv(.c) void {
            beginMessage();
            defer memory.endMessage();
            const pending = take(env);
            const rejection = Rejection{
                .code = @intCast(ic0.msg_reject_code()),
                .message = readMessage(ic0.msg_reject_msg_size, ic0.msg_reject_msg_copy),
            };
            if (comptime carries_pending) {
                defer finish(pending);
                checkOutcome(invoke(onReject, .{ pending, rejection }).outcome);
            } else {
                checkOutcome(invoke(onReject, .{rejection}).outcome);
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
/// stating how the message ended; the system wants neither. Both are in the
/// handler's signature, so every entry point's argument and reply types are
/// known at compile time.
///
/// A handler that sends no call can return the value itself. Anything other
/// than `void` or a `Transition` is encoded with `cdk_codec` and sent as the
/// reply, the same as returning `.reply(value)`. Returned as an error union,
/// an error rejects the message with the error's name. A `Transition` is only
/// needed to send a call, or to reject with text other than an error name.
///
/// A handler that allocates its reply takes a `std.mem.Allocator` first. Its
/// memory, like the decoded argument's, lasts until the message ends.
pub fn entryPoint(comptime func: anytype, comptime context: ic0.Context, comptime Codec: type) fn () void {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    const Returns = info.return_type orelse
        @compileError("an entry point may not have a generic return type");

    if (@typeInfo(Returns) == .error_union) {
        const Value = @typeInfo(Returns).error_union.payload;
        if (Value == void or isTransition(Value))
            @compileError("an entry point may return an error union only of a reply value, not " ++
                @typeName(Returns));
    }

    // Rejecting is allowed wherever replying is, so one check covers both.
    if (Returns != void and !ic0_spec.allows("msg_reply", context))
        @compileError("this entry point runs in a context that cannot reply, " ++
            "so its handler must return void, not " ++ @typeName(Returns));

    const params = info.param_types[@intFromBool(takesScratch(func))..];

    if (params.len == 0) {
        return struct {
            fn f() void {
                beginMessage();
                defer memory.endMessage();
                checkOutcome(outcomeOf(func, Codec, .{}));
            }
        }.f;
    }

    if (params.len != 1)
        @compileError("an entry point takes the decoded argument, optionally preceded by an allocator");

    // Reading the argument means calling msg_arg_data, which the spec does
    // not permit from every entry point. A pre_upgrade or timer handler has
    // no argument to read and would trap at runtime.
    if (!ic0_spec.allows("msg_arg_data_size", context))
        @compileError("this entry point runs in a context with no message argument, " ++
            "so its handler cannot take one");

    const Arg = params[0] orelse
        @compileError("an entry point may not take a generic parameter");

    return struct {
        fn f() void {
            beginMessage();
            defer memory.endMessage();
            const data = readMessage(ic0.msg_arg_data_size, ic0.msg_arg_data_copy);
            checkOutcome(outcomeOf(func, Codec, .{Codec.decode(Arg, data)}));
        }
    }.f;
}

// Null stands for an entry point returning void, which checkOutcome reads as
// one that cannot state an outcome.
fn outcomeOf(comptime func: anytype, comptime Codec: type, args: anytype) ?Outcome {
    const Returns = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    if (comptime Returns == void) {
        invoke(func, args);
        return null;
    }
    if (comptime isTransition(Returns)) return invoke(func, args).outcome;
    if (comptime @typeInfo(Returns) == .error_union) {
        const T = Transition(@typeInfo(Returns).error_union.payload);
        const value = invoke(func, args) catch |err|
            return T.reject(@errorName(err)).outcome;
        return T.replyWith(Codec, value).outcome;
    }
    return Transition(Returns).replyWith(Codec, invoke(func, args)).outcome;
}

// Copies the message's argument or reject text into scratch memory, which
// lasts until the message ends.
fn readMessage(comptime size: anytype, comptime copy: anytype) []const u8 {
    const len: usize = @intCast(size());
    const buf = memory.scratch.alloc(u8, len) catch trap("cdk: out of memory");
    if (len > 0) copy(buf.ptr, 0, @intCast(len));
    return buf;
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
