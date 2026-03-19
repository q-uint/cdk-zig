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

pub const Trace = struct {
    allocator: Allocator,
    lines: std.ArrayListUnmanaged(FoldedLine),
    names: std.AutoArrayHashMapUnmanaged(i32, []const u8),
    total_cost: i64,

    pub fn deinit(self: *Trace) void {
        for (self.lines.items) |line| {
            self.allocator.free(line.stack);
        }
        self.lines.deinit(self.allocator);
        for (self.names.values()) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
    }

    // Write folded stacks to a file. Each line is:
    //   func_a;func_b;func_c 1234
    pub fn writeFoldedStacks(self: *const Trace, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        for (self.lines.items) |line| {
            try file.writeAll(line.stack);
            var cost_buf: [32]u8 = undefined;
            const cost_str = std.fmt.bufPrint(&cost_buf, " {d}\n", .{line.cost}) catch unreachable;
            try file.writeAll(cost_str);
        }
    }
};

// Fetch profiling trace from a canister and convert to folded stacks.
pub fn fetch(
    allocator: Allocator,
    pocket: *pic.PocketIc,
    canister_id: []const u8,
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
        pic.principal.anonymous,
        "__get_profiling_names",
        "",
    );
    switch (names_result) {
        .reply => |data| {
            defer allocator.free(data);
            try parseNames(allocator, data, &names);
        },
        .reject => |msg| {
            allocator.free(msg);
            return error.ProfilingNamesRejected;
        },
    }

    // Fetch all trace pages.
    var all_entries = std.ArrayListUnmanaged(TraceEntry){};
    defer all_entries.deinit(allocator);

    var page: u32 = 0;
    while (true) {
        const result = try pocket.queryCall(
            canister_id,
            pic.principal.anonymous,
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
            .reject => |msg| {
                allocator.free(msg);
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
    var lines = std.ArrayListUnmanaged(FoldedLine){};
    errdefer {
        for (lines.items) |line| allocator.free(line.stack);
        lines.deinit(allocator);
    }

    var stack: [256]StackFrame = undefined;
    var depth: usize = 0;
    var total_cost: i64 = 0;

    for (entries) |entry| {
        if (entry.func_id > 0) {
            // Function entry.
            if (depth >= 256) continue;
            const name = names.get(entry.func_id) orelse "unknown";
            stack[depth] = .{
                .id = entry.func_id,
                .name = name,
                .enter_value = entryValue(entry, metric),
                .children_cost = 0,
            };
            depth += 1;
        } else if (entry.func_id < 0) {
            // Function exit.
            if (depth == 0) continue;
            const abs_id = -entry.func_id;
            // Find matching frame (should be top of stack).
            if (stack[depth - 1].id != abs_id) continue;
            depth -= 1;
            const frame = stack[depth];
            const exit_value = entryValue(entry, metric);
            const self_cost = exit_value - frame.enter_value - frame.children_cost;

            if (self_cost > 0) {
                // Build the stack string: "parent;child;grandchild"
                var path = std.ArrayListUnmanaged(u8){};
                defer path.deinit(allocator);
                for (0..depth + 1) |i| {
                    if (i > 0) try path.append(allocator, ';');
                    try path.appendSlice(allocator, stack[i].name);
                }
                const owned = try allocator.dupe(u8, path.items);
                try lines.append(allocator, .{ .stack = owned, .cost = self_cost });
                total_cost += self_cost;
            }

            // Propagate cost to parent.
            if (depth > 0) {
                stack[depth - 1].children_cost += exit_value - frame.enter_value;
            }
        }
    }

    return .{
        .allocator = allocator,
        .lines = lines,
        .names = names,
        .total_cost = total_cost,
    };
}
