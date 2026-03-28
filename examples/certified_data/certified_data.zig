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

fn set() void {
    const arg = cdk.argData();
    setTree(arg);
    cdk.replyRaw("");
}

// Query that returns the stored value along with the data certificate.
// Reply format: [32 bytes root_hash] [certificate bytes]
// The certificate is only available during query calls.
fn getWithProof() void {
    if (cdk.dataCertificate()) |cert| {
        const reply = cdk.allocator.alloc(u8, 32 + cert.len) catch {
            cdk.reject("alloc failed");
            return;
        };
        @memcpy(reply[0..32], &root_hash);
        @memcpy(reply[32..], cert);
        cdk.replyRaw(reply);
    } else {
        cdk.reject("no certificate available (not a query call?)");
    }
}

fn get() void {
    cdk.replyRaw(stored_value);
}

comptime {
    cdk.init(init);
    cdk.update(set, "set");
    cdk.query(get, "get");
    cdk.query(getWithProof, "get_with_proof");
}
