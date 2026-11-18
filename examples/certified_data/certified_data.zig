const std = @import("std");
const cdk = @import("cdk");
const HashTree = cdk.hash_tree.HashTree;
const Hash = cdk.hash_tree.Hash;

// Canister state: a single certified value stored under the label "data".
var stored_value: []const u8 = "";
var root_hash: Hash = std.mem.zeroes(Hash);

fn initTree() void {
    const empty: HashTree = .{ .empty = {} };
    root_hash = empty.reconstruct();
    cdk.certifiedDataSet(&root_hash);
}

fn setTree(value: []const u8) void {
    stored_value = value;
    const leaf: HashTree = .{ .leaf = value };
    const labeled: HashTree = .{ .labeled = .{ .label = "data", .child = &leaf } };
    root_hash = labeled.reconstruct();
    cdk.certifiedDataSet(&root_hash);
}

fn init() void {
    initTree();
}

// The argument lasts only for this message, so the kept value is a copy.
fn set(value: []const u8) void {
    const kept = cdk.persistent.dupe(u8, value) catch return cdk.reject("out of memory");
    cdk.persistent.free(stored_value);
    setTree(kept);
    cdk.replyRaw("");
}

// Query that returns the stored value along with the data certificate.
// Reply format: [32 bytes root_hash] [certificate bytes]
// The certificate is only available during query calls.
fn getWithProof(scratch: std.mem.Allocator) ![]const u8 {
    const cert = try cdk.dataCertificate(scratch) orelse return error.NoCertificate;
    return std.mem.concat(scratch, u8, &.{ &root_hash, cert });
}

fn get() []const u8 {
    return stored_value;
}

comptime {
    cdk.init(init);
    cdk.update(set, "set");
    cdk.query(get, "get");
    cdk.query(getWithProof, "get_with_proof");
}
