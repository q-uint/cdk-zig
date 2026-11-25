//! With `.inspect`, every `pub var` of the root source file that is a
//! stable log or typed log gets two dev endpoints, speaking Raw:
//! `__stable_<name>_len`, its entry count, and `__stable_<name>`, the entry
//! at an index as stored.

const std = @import("std");
const root = @import("root");
const build_options = @import("cdk_build_options");
const log = @import("stable/log.zig");
const memory = @import("stable/memory.zig");

pub const enabled = build_options.inspect;

/// The names of the root's pub logs.
pub const logs = Logs(memory, root).names;

/// The handlers of the log `name`'s endpoints.
pub fn Endpoints(comptime name: []const u8) type {
    return Logs(memory, root).Endpoints(name);
}

// Exact types only, so nothing else is mistaken for a log.
fn isLog(comptime Memory: type, comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "fixed_entry_size")) return T == log.Log(Memory, T.fixed_entry_size);
    if (@hasDecl(T, "Entry") and @hasDecl(T, "Codec"))
        return T == log.Typed(Memory, T.Entry, T.Codec);
    return false;
}

/// The logs over `Memory` among `Root`'s pub decls.
fn Logs(comptime Memory: type, comptime Root: type) type {
    return struct {
        const names = blk: {
            var found: []const []const u8 = &.{};
            for (@typeInfo(Root).@"struct".decl_names) |name| {
                if (isLog(Memory, @TypeOf(@field(Root, name)))) found = found ++ &[_][]const u8{name};
            }
            break :blk found;
        };

        fn Endpoints(comptime name: []const u8) type {
            const ptr = &@field(Root, name);
            const Bytes = if (@hasDecl(@TypeOf(ptr.*), "Entry")) @FieldType(@TypeOf(ptr.*), "raw") else @TypeOf(ptr.*);
            return struct {
                fn bytes() Bytes {
                    return if (Bytes == @TypeOf(ptr.*)) ptr.* else ptr.raw;
                }

                pub fn len() u64 {
                    return bytes().len();
                }

                pub fn get(a: std.mem.Allocator, index: u64) ![]const u8 {
                    const l = bytes();
                    const size = l.entrySize(index) orelse return error.OutOfRange;
                    const buf = try a.alloc(u8, @intCast(size));
                    const n = comptime Bytes.fixed_entry_size orelse 0;
                    if (n > 0) {
                        _ = l.get(index, buf[0..n]);
                    } else {
                        _ = l.get(index, buf).?;
                    }
                    return buf;
                }
            };
        }
    };
}

const testing_memory = @import("stable/testing.zig");

const TestRoot = struct {
    pub var ticks: log.Log(testing_memory, 8) = undefined;
    pub var blobs: log.Log(testing_memory, null) = undefined;
    var hidden: log.Log(testing_memory, null) = undefined;
    pub var counter: u64 = 0;
};

test "finds the pub logs" {
    const names = Logs(testing_memory, TestRoot).names;
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("ticks", names[0]);
    try std.testing.expectEqualStrings("blobs", names[1]);
}
