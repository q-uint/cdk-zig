const std = @import("std");
const pic = @import("pocket-ic");
const candid = @import("cdk").candid;

const allocator = std.testing.allocator;

const Greeting = struct {
    greeting: []const u8,
};

fn readWasm(name: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, name, 10 * 1024 * 1024);
}

test "callee greet" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    defer allocator.free(callee_id);
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const arg = try candid.encode(allocator, .{@as([]const u8, "world")});
    defer allocator.free(arg);

    const result = try pocket.queryCall(callee_id, pic.principal.anonymous, "greet", arg);
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            const g = try candid.decode(Greeting, allocator, data);
            defer allocator.free(g.greeting);
            try std.testing.expectEqualStrings("hello, world!", g.greeting);
        },
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

test "caller calls callee" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    defer allocator.free(callee_id);
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const callee_text = pic.principal.encode(callee_id);
    const caller_id = try pocket.createCanister();
    defer allocator.free(caller_id);
    try pocket.installCode(caller_id, caller_wasm, callee_text, .install);

    const result = try pocket.updateCall(caller_id, pic.principal.anonymous, "call_greet", "");
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            const g = try candid.decode(Greeting, allocator, data);
            defer allocator.free(g.greeting);
            try std.testing.expectEqualStrings("hello, world!", g.greeting);
        },
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}
