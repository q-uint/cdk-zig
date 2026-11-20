// Flamegraph trace utilities for use in tests (native, not wasm).
//
// Fetches profiling data from a canister via PocketIC, converts the
// trace entries into folded stack format, and writes to a file.
// The output can be piped through a flamegraph renderer:
//
//     inferno-flamegraph profile.folded > profile.svg
//
// Or with Brendan Gregg's tools:
//
//     flamegraph.pl profile.folded > profile.svg

const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket_ic.zig");

const Allocator = std.mem.Allocator;

const TraceEntry = extern struct {
    func_id: i32,
    instructions: i64,
    heap_bytes: i64,
    stable_pages: i64,
};

const entry_size = @sizeOf(TraceEntry);

pub const Metric = enum {
    instructions,
    heap_bytes,
    stable_pages,
};

const StackFrame = struct {
    id: i32,
    name: []const u8,
    enter_value: i64,
    children_cost: i64,
};

pub const FoldedLine = struct {
    stack: []const u8,
    cost: i64,
};

const Costs = std.StringArrayHashMapUnmanaged(i64);

pub const Trace = struct {
    allocator: Allocator,
    lines: std.ArrayListUnmanaged(FoldedLine),
    names: std.AutoArrayHashMapUnmanaged(i32, []const u8),
    total_cost: i64,
    inclusive_costs: Costs,
    exclusive_costs: Costs,
    /// Frames closed by an enclosing frame's exit rather than their own, an
    /// `exit` skipped by an early return say. Each was charged up to that
    /// enclosing exit.
    unbalanced: usize,

    /// The cost of every frame named `name`, its callees included. Recursive
    /// frames count once.
    pub fn inclusive(self: *const Trace, name: []const u8) i64 {
        return self.inclusive_costs.get(name) orelse 0;
    }

    /// The cost of every frame named `name`, its callees excluded.
    pub fn exclusive(self: *const Trace, name: []const u8) i64 {
        return self.exclusive_costs.get(name) orelse 0;
    }

    pub fn deinit(self: *Trace) void {
        for (self.lines.items) |line| {
            self.allocator.free(line.stack);
        }
        self.lines.deinit(self.allocator);
        self.inclusive_costs.deinit(self.allocator);
        self.exclusive_costs.deinit(self.allocator);
        for (self.names.values()) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
    }

    // Write folded stacks to a file. Each line is:
    //   func_a;func_b;func_c 1234
    pub fn writeFoldedStacks(self: *const Trace, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        for (self.lines.items) |line| {
            try file.writeStreamingAll(io, line.stack);
            var cost_buf: [32]u8 = undefined;
            const cost_str = std.fmt.bufPrint(&cost_buf, " {d}\n", .{line.cost}) catch unreachable;
            try file.writeStreamingAll(io, cost_str);
        }
    }
};

// Fetch profiling trace from a canister and convert to folded stacks.
pub fn fetch(
    allocator: Allocator,
    pocket: *pic.PocketIc,
    canister_id: cdk.principal.Principal,
    metric: Metric,
) !Trace {
    var names = std.AutoArrayHashMapUnmanaged(i32, []const u8){};
    errdefer {
        for (names.values()) |n| allocator.free(n);
        names.deinit(allocator);
    }

    // Fetch name table.
    const names_result = try pocket.queryCall(
        canister_id,
        cdk.principal.anonymous,
        "__get_profiling_names",
        "",
    );
    switch (names_result) {
        .reply => |data| {
            defer allocator.free(data);
            try parseNames(allocator, data, &names);
        },
        .reject => |rej| {
            rej.deinit(allocator);
            return error.ProfilingNamesRejected;
        },
    }

    // Fetch all trace pages.
    var all_entries: std.ArrayListUnmanaged(TraceEntry) = .empty;
    defer all_entries.deinit(allocator);

    var page: u32 = 0;
    while (true) {
        const result = try pocket.queryCall(
            canister_id,
            cdk.principal.anonymous,
            "__get_profiling",
            &std.mem.toBytes(page),
        );
        switch (result) {
            .reply => |data| {
                defer allocator.free(data);
                if (data.len < @sizeOf(i32)) break;

                const trailer = data[data.len - @sizeOf(i32) ..];
                const next_page = std.mem.readInt(i32, trailer[0..4], .little);
                const body = data[0 .. data.len - @sizeOf(i32)];
                const count = body.len / entry_size;

                if (count > 0) {
                    const entries: []const TraceEntry = @alignCast(
                        std.mem.bytesAsSlice(TraceEntry, body[0 .. count * entry_size]),
                    );
                    try all_entries.appendSlice(allocator, entries);
                }

                if (next_page < 0) break;
                page = @intCast(next_page);
            },
            .reject => |rej| {
                rej.deinit(allocator);
                return error.ProfilingDataRejected;
            },
        }
    }

    // Convert trace entries to folded stacks.
    return buildFoldedStacks(allocator, all_entries.items, names, metric);
}

fn parseNames(
    allocator: Allocator,
    data: []const u8,
    names: *std.AutoArrayHashMapUnmanaged(i32, []const u8),
) !void {
    var offset: usize = 0;
    while (offset + 8 <= data.len) {
        const id = std.mem.readInt(i32, data[offset..][0..4], .little);
        offset += 4;
        const name_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (offset + name_len > data.len) break;
        const name = try allocator.dupe(u8, data[offset..][0..name_len]);
        try names.put(allocator, id, name);
        offset += name_len;
    }
}

fn entryValue(entry: TraceEntry, metric: Metric) i64 {
    return switch (metric) {
        .instructions => entry.instructions,
        .heap_bytes => entry.heap_bytes,
        .stable_pages => entry.stable_pages,
    };
}

fn buildFoldedStacks(
    allocator: Allocator,
    entries: []const TraceEntry,
    names: std.AutoArrayHashMapUnmanaged(i32, []const u8),
    metric: Metric,
) !Trace {
    var folder: Folder = .{ .allocator = allocator };
    errdefer folder.deinit();

    for (entries) |entry| {
        if (entry.func_id > 0) {
            // Function entry.
            if (folder.depth >= max_depth) continue;
            folder.stack[folder.depth] = .{
                .id = entry.func_id,
                .name = names.get(entry.func_id) orelse "unknown",
                .enter_value = entryValue(entry, metric),
                .children_cost = 0,
            };
            folder.depth += 1;
        } else if (entry.func_id < 0) {
            // Function exit. Frames above the matching one never saw their
            // own exit, so they close here too. An exit with no matching
            // frame is dropped.
            const id = -entry.func_id;
            const target = for (0..folder.depth) |i| {
                const index = folder.depth - 1 - i;
                if (folder.stack[index].id == id) break index;
            } else continue;
            const exit_value = entryValue(entry, metric);
            while (folder.depth > target + 1) {
                try folder.close(exit_value);
                folder.unbalanced += 1;
            }
            try folder.close(exit_value);
        }
    }

    return .{
        .allocator = allocator,
        .lines = folder.lines,
        .names = names,
        .total_cost = folder.total_cost,
        .inclusive_costs = folder.inclusive_costs,
        .exclusive_costs = folder.exclusive_costs,
        .unbalanced = folder.unbalanced,
    };
}

const max_depth = 256;

const Folder = struct {
    allocator: Allocator,
    stack: [max_depth]StackFrame = undefined,
    depth: usize = 0,
    lines: std.ArrayListUnmanaged(FoldedLine) = .empty,
    total_cost: i64 = 0,
    inclusive_costs: Costs = .empty,
    exclusive_costs: Costs = .empty,
    unbalanced: usize = 0,

    fn deinit(self: *Folder) void {
        for (self.lines.items) |line| self.allocator.free(line.stack);
        self.lines.deinit(self.allocator);
        self.inclusive_costs.deinit(self.allocator);
        self.exclusive_costs.deinit(self.allocator);
    }

    // Closes the top frame at `exit_value`.
    fn close(self: *Folder, exit_value: i64) !void {
        self.depth -= 1;
        const frame = self.stack[self.depth];
        const cost = exit_value - frame.enter_value;
        const self_cost = cost - frame.children_cost;

        try add(self.allocator, &self.exclusive_costs, frame.name, self_cost);
        const recursive = for (self.stack[0..self.depth]) |outer| {
            if (outer.id == frame.id) break true;
        } else false;
        if (!recursive) try add(self.allocator, &self.inclusive_costs, frame.name, cost);

        if (self_cost > 0) {
            // Build the stack string: "parent;child;grandchild"
            var path: std.ArrayListUnmanaged(u8) = .empty;
            defer path.deinit(self.allocator);
            for (self.stack[0 .. self.depth + 1], 0..) |f, i| {
                if (i > 0) try path.append(self.allocator, ';');
                try path.appendSlice(self.allocator, f.name);
            }
            const owned = try self.allocator.dupe(u8, path.items);
            errdefer self.allocator.free(owned);
            try self.lines.append(self.allocator, .{ .stack = owned, .cost = self_cost });
            self.total_cost += self_cost;
        }

        // Propagate cost to parent.
        if (self.depth > 0) self.stack[self.depth - 1].children_cost += cost;
    }

    fn add(allocator: Allocator, costs: *Costs, name: []const u8, cost: i64) !void {
        const slot = try costs.getOrPut(allocator, name);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += cost;
    }
};

/// Drives a profiling build of a canister from a test. Arguments are encoded
/// with `Codec`, as `Canister(Codec)` does.
pub fn Profiler(comptime Codec: type) type {
    return struct {
        pic: *pic.PocketIc,
        id: cdk.principal.Principal,
        sender: cdk.principal.Principal = cdk.principal.anonymous,

        const Self = @This();

        pub const Options = struct {
            /// Keep only the trace of the latest traced call.
            last_call_only: bool = false,
        };

        /// Starts a fresh trace.
        pub fn start(self: Self, options: Options) !void {
            try self.set(true, options.last_call_only);
        }

        pub fn stop(self: Self) !void {
            try self.set(false, false);
        }

        /// The trace recorded so far.
        pub fn trace(self: Self, allocator: Allocator, metric: Metric) !Trace {
            return fetch(allocator, self.pic, self.id, metric);
        }

        /// Runs one update and returns its trace. Tracing stays on, last
        /// call only. Pass `{}` as `arg` for a method that takes none.
        pub fn profile(
            self: Self,
            allocator: Allocator,
            method: []const u8,
            arg: anytype,
            metric: Metric,
        ) !Trace {
            try self.start(.{ .last_call_only = true });
            try self.call(method, arg);
            return self.trace(allocator, metric);
        }

        /// `profile` for a query, through its `__profile_<name>` update.
        pub fn profileQuery(
            self: Self,
            allocator: Allocator,
            method: []const u8,
            arg: anytype,
            metric: Metric,
        ) !Trace {
            const update = try std.mem.concat(
                self.pic.allocator,
                u8,
                &.{ cdk.profiling.query_prefix, method },
            );
            defer self.pic.allocator.free(update);
            return self.profile(allocator, update, arg, metric);
        }

        fn set(self: Self, tracing: bool, entry_mode: bool) !void {
            const settings = [2]u8{ @intFromBool(tracing), @intFromBool(entry_mode) };
            const result = try self.pic.updateCall(
                self.id,
                self.sender,
                "__set_profiling",
                &settings,
            );
            try expectReply(self.pic, "__set_profiling", result);
        }

        fn call(self: Self, method: []const u8, arg: anytype) !void {
            var scratch = std.heap.ArenaAllocator.init(self.pic.allocator);
            defer scratch.deinit();
            const payload = if (@TypeOf(arg) == void)
                ""
            else
                try Codec.encode(scratch.allocator(), @TypeOf(arg), arg);
            const result = try self.pic.updateCall(self.id, self.sender, method, payload);
            try expectReply(self.pic, method, result);
        }
    };
}

fn expectReply(pocket: *pic.PocketIc, method: []const u8, result: pic.WasmResult) !void {
    switch (result) {
        .reply => |data| pocket.allocator.free(data),
        .reject => |rej| {
            defer rej.deinit(pocket.allocator);
            std.log.debug("{s} was rejected ({t}): {s}", .{ method, rej.code, rej.message });
            return error.Rejected;
        },
    }
}

const testing = std.testing;

const Names = std.AutoArrayHashMapUnmanaged(i32, []const u8);

fn testNames(pairs: []const struct { i32, []const u8 }) !Names {
    const a = testing.allocator;
    var names: Names = .{};
    errdefer {
        for (names.values()) |n| a.free(n);
        names.deinit(a);
    }
    for (pairs) |pair| try names.put(a, pair[0], try a.dupe(u8, pair[1]));
    return names;
}

fn testTrace(entries: []const TraceEntry, names: []const struct { i32, []const u8 }) !Trace {
    return buildFoldedStacks(testing.allocator, entries, try testNames(names), .instructions);
}

fn at(id: i32, instructions: i64) TraceEntry {
    return .{
        .func_id = id,
        .instructions = instructions,
        .heap_bytes = 0,
        .stable_pages = 0,
    };
}

test "inclusive and exclusive costs" {
    // a [0, 100) calls b [10, 40) and b [50, 60).
    const entries = [_]TraceEntry{
        at(1, 0), at(2, 10), at(-2, 40), at(2, 50), at(-2, 60), at(-1, 100),
    };
    var trace = try testTrace(&entries, &.{ .{ 1, "a" }, .{ 2, "b" } });
    defer trace.deinit();

    try testing.expectEqual(@as(i64, 100), trace.inclusive("a"));
    try testing.expectEqual(@as(i64, 60), trace.exclusive("a"));
    try testing.expectEqual(@as(i64, 40), trace.inclusive("b"));
    try testing.expectEqual(@as(i64, 40), trace.exclusive("b"));
    try testing.expectEqual(@as(i64, 100), trace.total_cost);
    try testing.expectEqual(@as(usize, 0), trace.unbalanced);
}

test "recursive frames count once inclusively" {
    const entries = [_]TraceEntry{ at(1, 0), at(1, 10), at(-1, 30), at(-1, 50) };
    var trace = try testTrace(&entries, &.{.{ 1, "a" }});
    defer trace.deinit();

    try testing.expectEqual(@as(i64, 50), trace.inclusive("a"));
    try testing.expectEqual(@as(i64, 50), trace.exclusive("a"));
}

test "an enclosing exit closes a frame missing its own" {
    // b never exits, so a's exit closes it.
    const entries = [_]TraceEntry{ at(1, 0), at(2, 10), at(-1, 40) };
    var trace = try testTrace(&entries, &.{ .{ 1, "a" }, .{ 2, "b" } });
    defer trace.deinit();

    try testing.expectEqual(@as(usize, 1), trace.unbalanced);
    try testing.expectEqual(@as(i64, 40), trace.inclusive("a"));
    try testing.expectEqual(@as(i64, 30), trace.inclusive("b"));
    try testing.expectEqual(@as(usize, 2), trace.lines.items.len);
}
