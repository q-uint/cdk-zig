const std = @import("std");
const pic = @import("pocket-ic");
const cdk = @import("cdk");
const Sha256 = std.crypto.hash.sha2.Sha256;
const hash_tree = cdk.hash_tree;
const cbor = cdk.cbor;

const allocator = std.testing.allocator;

fn deploy(pocket: *pic.PocketIc) !pic.Canister(cdk.RawCodec) {
    return pocket.canister(cdk.RawCodec, try pocket.deploy("zig-out/bin/certified_data.wasm", ""));
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
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = "hello certified world";
    _ = try store.update(a, []const u8, "set", value);
    try std.testing.expectEqualStrings(value, try store.query(a, []const u8, "get", {}));
}

test "get_with_proof returns certificate with correct certified_data" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = "hello certified world";
    _ = try store.update(a, []const u8, "set", value);

    // Query with proof returns [32 bytes root_hash] [certificate CBOR]
    const reply = try store.query(a, []const u8, "get_with_proof", {});

    try std.testing.expect(reply.len > 32);
    const returned_hash = reply[0..32];
    const cert_bytes = reply[32..];

    // Verify the root hash matches local computation.
    const expected_hash = labeledHash("data", leafHash(value));
    try std.testing.expectEqualSlices(u8, &expected_hash, returned_hash);

    // Parse the certificate and verify certified_data matches.
    const certified_data = try extractCertifiedData(store.id.slice(), cert_bytes);
    try std.testing.expectEqualSlices(u8, &expected_hash, certified_data);
}

test "overwrite updates certified_data in certificate" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Set first value and verify.
    const v1 = "first";
    _ = try store.update(a, []const u8, "set", v1);

    const proof1 = try store.query(a, []const u8, "get_with_proof", {});
    const cd1 = try extractCertifiedData(store.id.slice(), proof1[32..]);
    const expected1 = labeledHash("data", leafHash(v1));
    try std.testing.expectEqualSlices(u8, &expected1, cd1);

    // Set second value and verify it changed.
    const v2 = "second";
    _ = try store.update(a, []const u8, "set", v2);

    const proof2 = try store.query(a, []const u8, "get_with_proof", {});
    const cd2 = try extractCertifiedData(store.id.slice(), proof2[32..]);
    const expected2 = labeledHash("data", leafHash(v2));
    try std.testing.expectEqualSlices(u8, &expected2, cd2);

    // Must be different.
    try std.testing.expect(!std.mem.eql(u8, cd1, cd2));
}

test "certificate BLS signature verifies against root key" {
    var pocket = try pic.PocketIc.initTesting();
    defer pocket.deinit();
    const store = try deploy(&pocket);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try store.update(arena.allocator(), []const u8, "set", "bls verified");

    // Get a certificate via read_state.
    const paths = [_][]const []const u8{
        &.{ "canister", store.id.slice(), "module_hash" },
    };
    var cert = try pocket.readStateCertificate(store.id, &paths);
    defer cert.deinit();

    // Verify the BLS signature on the certificate.
    try pocket.verifyCertificate(&cert);
}
