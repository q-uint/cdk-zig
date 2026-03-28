const std = @import("std");
const pic = @import("pocket-ic");
const cdk = @import("cdk");
const Sha256 = std.crypto.hash.sha2.Sha256;
const hash_tree = cdk.hash_tree;
const cbor = cdk.cbor;

const allocator = std.testing.allocator;

fn readWasm() ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, "zig-out/bin/certified_data.wasm", 10 * 1024 * 1024);
}

fn expectReply(
    pocket: *pic.PocketIc,
    cid: []const u8,
    method: []const u8,
    arg: []const u8,
    comptime call_type: enum { query, update },
) ![]const u8 {
    const result = switch (call_type) {
        .query => try pocket.queryCall(cid, pic.principal.anonymous, method, arg),
        .update => try pocket.updateCall(cid, pic.principal.anonymous, method, arg),
    };
    switch (result) {
        .reply => |data| return data,
        .reject => |msg| {
            defer allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

fn leafHash(value: []const u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update("\x10ic-hashtree-leaf");
    h.update(value);
    return h.finalResult();
}

fn labeledHash(label: []const u8, child_hash: [32]u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update("\x13ic-hashtree-labeled");
    h.update(label);
    h.update(&child_hash);
    return h.finalResult();
}

// Parse a certificate from raw CBOR bytes and look up certified_data.
fn extractCertifiedData(
    canister_id: []const u8,
    cert_bytes: []const u8,
) ![]const u8 {
    var data = cert_bytes;
    // Skip self-describe tag if present.
    if (data.len >= 3 and data[0] == 0xd9 and data[1] == 0xd9 and data[2] == 0xf7) {
        data = data[3..];
    }
    const decoded = try cbor.decodeValue(data);
    const cert_map = switch (decoded.value) {
        .map => |m| m,
        else => return error.InvalidCertificate,
    };

    const raw = try cbor.mapLookupRaw(cert_map, "tree") orelse return error.InvalidCertificate;
    var tree = try hash_tree.HashTree.decodeCbor(allocator, raw);
    defer tree.deinit();

    const result = tree.root.?.lookupPath(
        &.{ "canister", canister_id, "certified_data" },
    );
    switch (result) {
        .found => |d| return d,
        else => return error.CertifiedDataNotFound,
    }
}

test "set and get round-trip" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const value = "hello certified world";
    const set_reply = try expectReply(&pocket, cid, "set", value, .update);
    allocator.free(set_reply);

    const get_reply = try expectReply(&pocket, cid, "get", "", .query);
    defer allocator.free(get_reply);
    try std.testing.expectEqualStrings(value, get_reply);
}

test "get_with_proof returns certificate with correct certified_data" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const value = "hello certified world";
    const set_reply = try expectReply(&pocket, cid, "set", value, .update);
    allocator.free(set_reply);

    // Query with proof returns [32 bytes root_hash] [certificate CBOR]
    const reply = try expectReply(&pocket, cid, "get_with_proof", "", .query);
    defer allocator.free(reply);

    try std.testing.expect(reply.len > 32);
    const returned_hash = reply[0..32];
    const cert_bytes = reply[32..];

    // Verify the root hash matches local computation.
    const expected_hash = labeledHash("data", leafHash(value));
    try std.testing.expectEqualSlices(u8, &expected_hash, returned_hash);

    // Parse the certificate and verify certified_data matches.
    const certified_data = try extractCertifiedData(cid, cert_bytes);
    try std.testing.expectEqualSlices(u8, &expected_hash, certified_data);
}

test "overwrite updates certified_data in certificate" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    // Set first value and verify.
    const v1 = "first";
    const r1 = try expectReply(&pocket, cid, "set", v1, .update);
    allocator.free(r1);

    const proof1 = try expectReply(&pocket, cid, "get_with_proof", "", .query);
    defer allocator.free(proof1);
    const cd1 = try extractCertifiedData(cid, proof1[32..]);
    const expected1 = labeledHash("data", leafHash(v1));
    try std.testing.expectEqualSlices(u8, &expected1, cd1);

    // Set second value and verify it changed.
    const v2 = "second";
    const r2 = try expectReply(&pocket, cid, "set", v2, .update);
    allocator.free(r2);

    const proof2 = try expectReply(&pocket, cid, "get_with_proof", "", .query);
    defer allocator.free(proof2);
    const cd2 = try extractCertifiedData(cid, proof2[32..]);
    const expected2 = labeledHash("data", leafHash(v2));
    try std.testing.expectEqualSlices(u8, &expected2, cd2);

    // Must be different.
    try std.testing.expect(!std.mem.eql(u8, cd1, cd2));
}

test "certificate BLS signature verifies against root key" {
    const wasm = try readWasm();
    defer allocator.free(wasm);

    var pocket = try pic.PocketIc.init(allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer allocator.free(cid);
    try pocket.installCode(cid, wasm, "", .install);

    const value = "bls verified";
    const set_reply = try expectReply(&pocket, cid, "set", value, .update);
    allocator.free(set_reply);

    // Get a certificate via read_state.
    const paths = [_][]const []const u8{
        &.{ "canister", cid, "module_hash" },
    };
    var cert = try pocket.readStateCertificate(cid, &paths);
    defer cert.deinit();

    // Verify the BLS signature on the certificate.
    try pocket.verifyCertificate(&cert);
}
