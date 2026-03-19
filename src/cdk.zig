const std = @import("std");

pub const principal = @import("principal.zig");
pub const ic0 = @import("ic0.zig");
pub const call = @import("call.zig");
pub const stable = @import("stable.zig");
const exp = @import("export.zig");

pub const timers = @import("timers.zig");
pub const executor = @import("executor.zig");
pub const profiling = @import("profiling.zig");

pub const allocator = @import("allocator.zig").default;

// Export decorators
pub const init = exp.init;
pub const query = exp.query;
pub const update = exp.update;
pub const preUpgrade = exp.preUpgrade;
pub const postUpgrade = exp.postUpgrade;
pub const heartbeat = exp.heartbeat;
pub const inspectMessage = exp.inspectMessage;
pub const globalTimer = exp.globalTimer;
pub const onLowWasmMemory = exp.onLowWasmMemory;

pub const CanisterStatusCode = enum(u32) {
    running = 1,
    stopping = 2,
    stopped = 3,
    _,
};

pub const PerformanceCounterType = enum(u32) {
    instructionCounter = 0,
    callContextInstructionCounter = 1,
    _,
};

pub const RejectCode = enum(u32) {
    sysFatal = 1,
    sysTransient = 2,
    destinationInvalid = 3,
    canisterReject = 4,
    canisterError = 5,
    sysUnknown = 6,
    _,
};

pub const SignCostError = error{
    InvalidCurveOrAlgorithm,
    InvalidKeyName,
    UnrecognizedError,
};

// Debug/trap
pub fn print(msg: []const u8) void {
    ic0.debug_print(msg.ptr, @intCast(msg.len));
}

pub fn trap(msg: []const u8) noreturn {
    ic0.trap(msg.ptr, @intCast(msg.len));
    unreachable;
}

// Message input
pub fn caller() principal.Principal {
    const len = ic0.msg_caller_size();
    const bytes = allocator.alloc(
        u8,
        @intCast(len),
    ) catch @panic("failed to allocate memory");
    ic0.msg_caller_copy(bytes.ptr, 0, len);
    return bytes;
}

pub fn argData() []const u8 {
    const size: u32 = @intCast(ic0.msg_arg_data_size());
    if (size == 0) return &.{};
    const buf = allocator.alloc(u8, size) catch
        @panic("failed to allocate memory");
    ic0.msg_arg_data_copy(buf.ptr, 0, @intCast(size));
    return buf;
}

pub fn msgRejectCode() RejectCode {
    return @enumFromInt(@as(u32, @intCast(ic0.msg_reject_code())));
}

pub fn msgRejectMsg() []const u8 {
    const len: u32 = @intCast(ic0.msg_reject_msg_size());
    if (len == 0) return &.{};
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.msg_reject_msg_copy(buf.ptr, 0, @intCast(len));
    return buf;
}

pub fn msgDeadline() u64 {
    return @intCast(ic0.msg_deadline());
}

pub fn msgMethodName() []const u8 {
    const len: u32 = @intCast(ic0.msg_method_name_size());
    if (len == 0) return &.{};
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.msg_method_name_copy(buf.ptr, 0, @intCast(len));
    return buf;
}

pub fn acceptMessage() void {
    ic0.accept_message();
}

// Message output
pub fn replyRaw(msg: []const u8) void {
    if (msg.len != 0) {
        ic0.msg_reply_data_append(msg.ptr, @intCast(msg.len));
    }
    ic0.msg_reply();
}

pub fn reject(msg: []const u8) void {
    ic0.msg_reject(msg.ptr, @intCast(msg.len));
}

// Cycles (message-level)
pub fn msgCyclesAvailable128() u128 {
    var dst: [16]u8 = undefined;
    ic0.msg_cycles_available128(&dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn msgCyclesRefunded128() u128 {
    var dst: [16]u8 = undefined;
    ic0.msg_cycles_refunded128(&dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn msgCyclesAccept128(max_amount: u128) u128 {
    const high: i64 = @bitCast(@as(u64, @truncate(max_amount >> 64)));
    const low: i64 = @bitCast(@as(u64, @truncate(max_amount)));
    var dst: [16]u8 = undefined;
    ic0.msg_cycles_accept128(high, low, &dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn cyclesBurn128(amount: u128) u128 {
    const high: i64 = @bitCast(@as(u64, @truncate(amount >> 64)));
    const low: i64 = @bitCast(@as(u64, @truncate(amount)));
    var dst: [16]u8 = undefined;
    ic0.cycles_burn128(high, low, &dst);
    return std.mem.readInt(u128, &dst, .little);
}

// Canister info
pub fn canisterSelf() principal.Principal {
    const len = ic0.canister_self_size();
    const bytes = allocator.alloc(u8, @intCast(len)) catch
        @panic("failed to allocate memory");
    ic0.canister_self_copy(bytes.ptr, 0, len);
    return bytes;
}

pub fn canisterCycleBalance128() u128 {
    var dst: [16]u8 = undefined;
    ic0.canister_cycle_balance128(&dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn canisterLiquidCycleBalance128() u128 {
    var dst: [16]u8 = undefined;
    ic0.canister_liquid_cycle_balance128(&dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn canisterStatus() CanisterStatusCode {
    return @enumFromInt(@as(u32, @intCast(ic0.canister_status())));
}

pub fn canisterVersion() u64 {
    return @intCast(ic0.canister_version());
}

// Subnet info
pub fn subnetSelf() principal.Principal {
    const len = ic0.subnet_self_size();
    const bytes = allocator.alloc(u8, @intCast(len)) catch
        @panic("failed to allocate memory");
    ic0.subnet_self_copy(bytes.ptr, 0, len);
    return bytes;
}

// Time and timers
pub fn time() u64 {
    return @intCast(ic0.time());
}

pub fn globalTimerSet(timestamp: u64) u64 {
    return @intCast(ic0.global_timer_set(@intCast(timestamp)));
}

// Performance
pub fn performanceCounter(counter_type: PerformanceCounterType) u64 {
    return @intCast(ic0.performance_counter(@intCast(@intFromEnum(counter_type))));
}

pub fn instructionCounter() u64 {
    return performanceCounter(.instructionCounter);
}

pub fn callContextInstructionCounter() u64 {
    return performanceCounter(.callContextInstructionCounter);
}

// Authorization
pub fn isController(p: principal.Principal) bool {
    return ic0.is_controller(p.ptr, @intCast(p.len)) != 0;
}

// Execution context
pub fn inReplicatedExecution() bool {
    return ic0.in_replicated_execution() != 0;
}

// Certified data
pub fn certifiedDataSet(data: []const u8) void {
    ic0.certified_data_set(data.ptr, @intCast(data.len));
}

pub fn dataCertificate() ?[]const u8 {
    if (ic0.data_certificate_present() == 0) return null;
    const len: u32 = @intCast(ic0.data_certificate_size());
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.data_certificate_copy(buf.ptr, 0, @intCast(len));
    return buf;
}

pub fn rootKey() []const u8 {
    const len: u32 = @intCast(ic0.root_key_size());
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.root_key_copy(buf.ptr, 0, @intCast(len));
    return buf;
}

// Stable memory (convenience wrappers using 64-bit API)
pub fn stableSize() u64 {
    return @intCast(ic0.stable64_size());
}

pub fn stableGrow(new_pages: u64) u64 {
    return @intCast(ic0.stable64_grow(@intCast(new_pages)));
}

pub fn stableWrite(offset: u64, buf: []const u8) void {
    ic0.stable64_write(@intCast(offset), @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len));
}

pub fn stableRead(offset: u64, buf: []u8) void {
    ic0.stable64_read(@intCast(@intFromPtr(buf.ptr)), @intCast(offset), @intCast(buf.len));
}

// Cost estimation
pub fn costCall(method_name_size: u64, payload_size: u64) u128 {
    var dst: [16]u8 = undefined;
    ic0.cost_call(@intCast(method_name_size), @intCast(payload_size), &dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn costCreateCanister() u128 {
    var dst: [16]u8 = undefined;
    ic0.cost_create_canister(&dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn costHttpRequest(request_size: u64, max_response_bytes: u64) u128 {
    var dst: [16]u8 = undefined;
    ic0.cost_http_request(@intCast(request_size), @intCast(max_response_bytes), &dst);
    return std.mem.readInt(u128, &dst, .little);
}

pub fn costSignWithEcdsa(key_name: []const u8, ecdsa_curve: u32) SignCostError!u128 {
    var dst: [16]u8 = undefined;
    const code = ic0.cost_sign_with_ecdsa(key_name.ptr, @intCast(key_name.len), @intCast(ecdsa_curve), &dst);
    return signCostResult(&dst, @intCast(code));
}

pub fn costSignWithSchnorr(key_name: []const u8, algorithm: u32) SignCostError!u128 {
    var dst: [16]u8 = undefined;
    const code = ic0.cost_sign_with_schnorr(key_name.ptr, @intCast(key_name.len), @intCast(algorithm), &dst);
    return signCostResult(&dst, @intCast(code));
}

pub fn costVetkdDeriveKey(key_name: []const u8, vetkd_curve: u32) SignCostError!u128 {
    var dst: [16]u8 = undefined;
    const code = ic0.cost_vetkd_derive_key(key_name.ptr, @intCast(key_name.len), @intCast(vetkd_curve), &dst);
    return signCostResult(&dst, @intCast(code));
}

fn signCostResult(dst: *const [16]u8, code: u32) SignCostError!u128 {
    return switch (code) {
        0 => std.mem.readInt(u128, dst, .little),
        1 => SignCostError.InvalidCurveOrAlgorithm,
        2 => SignCostError.InvalidKeyName,
        else => SignCostError.UnrecognizedError,
    };
}

// Environment variables
pub fn envVarCount() u32 {
    return @intCast(ic0.env_var_count());
}

pub fn envVarName(index: u32) []const u8 {
    const len: u32 = @intCast(ic0.env_var_name_size(@intCast(index)));
    if (len == 0) return &.{};
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.env_var_name_copy(@intCast(index), buf.ptr, 0, @intCast(len));
    return buf;
}

pub fn envVarNameExists(name: []const u8) bool {
    return ic0.env_var_name_exists(name.ptr, @intCast(name.len)) != 0;
}

pub fn envVarValue(name: []const u8) []const u8 {
    const len: u32 = @intCast(ic0.env_var_value_size(name.ptr, @intCast(name.len)));
    if (len == 0) return &.{};
    const buf = allocator.alloc(u8, len) catch
        @panic("failed to allocate memory");
    ic0.env_var_value_copy(name.ptr, @intCast(name.len), buf.ptr, 0, @intCast(len));
    return buf;
}
