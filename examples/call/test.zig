const std = @import("std");
const cdk = @import("cdk");
const pic = @import("pocket-ic");

const allocator = std.testing.allocator;

fn initPic() !pic.PocketIc {
    const bin = std.testing.environ.getPosix("POCKET_IC_BIN") orelse return error.SkipZigTest;
    return pic.PocketIc.init(std.testing.io, allocator, .{ .bin_path = bin });
}

fn readWasm(name: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, name, allocator, .limited(10 * 1024 * 1024));
}

fn expectReply(result: pic.WasmResult, expected: []const u8) !void {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(expected, data);
        },
        .reject => |rej| {
            defer rej.deinit(allocator);
            std.debug.print("rejected: {s}\n", .{rej.message});
            return error.Rejected;
        },
    }
}

fn expectReject(result: pic.WasmResult) !pic.Reject {
    switch (result) {
        .reply => |data| {
            defer allocator.free(data);
            return error.ExpectedReject;
        },
        .reject => |rej| return rej,
    }
}

fn installCaller(pocket: *pic.PocketIc, callee: []const u8) !cdk.principal.Principal {
    const caller_wasm = try readWasm("zig-out/bin/caller.wasm");
    defer allocator.free(caller_wasm);

    const caller_id = try pocket.createCanister();
    try pocket.installCode(caller_id, caller_wasm, callee, .install);
    return caller_id;
}

fn installPair(pocket: *pic.PocketIc) !cdk.principal.Principal {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);
    return installCaller(pocket, callee_id.slice());
}

test "callee greet" {
    const callee_wasm = try readWasm("zig-out/bin/callee.wasm");
    defer allocator.free(callee_wasm);

    var pocket = try initPic();
    defer pocket.deinit();

    const callee_id = try pocket.createCanister();
    try pocket.installCode(callee_id, callee_wasm, "", .install);

    const result = try pocket.queryCall(callee_id, cdk.principal.anonymous, "greet", "");
    try expectReply(result, "hello from callee");
}

test "caller greet" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installCaller(&pocket, "");

    const result = try pocket.queryCall(caller_id, cdk.principal.anonymous, "greet", "");
    try expectReply(result, "hello from caller");
}

test "caller calls callee" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    try expectReply(result, "hello from callee");
}

test "a continuation can send the next call" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installPair(&pocket);

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_chained", "");
    try expectReply(result, "hello from callee and goodbye from callee");
}

test "caller without callee principal rejects call_greet" {
    var pocket = try initPic();
    defer pocket.deinit();

    const caller_id = try installCaller(&pocket, "");

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expect(rej.message.len > 0);
}

test "caller calls non-existent canister" {
    var pocket = try initPic();
    defer pocket.deinit();

    // Point the caller at the management canister, which has no greet.
    const caller_id = try installCaller(&pocket, cdk.principal.management_canister.slice());

    const result = try pocket.updateCall(caller_id, cdk.principal.anonymous, "call_greet", "");
    const rej = try expectReject(result);
    defer rej.deinit(allocator);
    try std.testing.expect(rej.message.len > 0);
}
