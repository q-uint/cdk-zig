const std = @import("std");

pub const principal = @import("principal.zig");
pub const ic0 = @import("ic0.zig");
pub const call = @import("call.zig");
const exp = @import("export.zig");

pub const allocator = std.heap.page_allocator;

pub const init = exp.init;
pub const query = exp.query;
pub const update = exp.update;

pub fn print(msg: []const u8) void {
    ic0.debug_print(msg.ptr, @intCast(msg.len));
}

pub fn trap(msg: []const u8) void {
    ic0.trap(msg.ptr, @intCast(msg.len));
}

pub fn caller() principal.Principal {
    const len = ic0.msg_caller_size();
    const bytes = allocator.alloc(
        u8,
        @intCast(len),
    ) catch @panic("failed to allocate memory");
    ic0.msg_caller_copy(bytes.ptr, 0, len);
    return bytes;
}

pub fn time() u64 {
    return @intCast(ic0.time());
}

pub fn arg_data() []const u8 {
    const size: u32 = @intCast(ic0.msg_arg_data_size());
    if (size == 0) return &.{};
    const buf = allocator.alloc(u8, size) catch
        @panic("failed to allocate memory");
    ic0.msg_arg_data_copy(buf.ptr, 0, @intCast(size));
    return buf;
}

pub fn reply_raw(msg: []const u8) void {
    if (msg.len != 0) {
        ic0.msg_reply_data_append(msg.ptr, @intCast(msg.len));
    }
    ic0.msg_reply();
}
