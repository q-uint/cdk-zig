const std = @import("std");
const cbor = @import("cbor.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [Sha256.digest_length]u8;

pub const LookupResult = union(enum) {
    found: []const u8,
    absent,
    unknown,
};

// Domain-separated hash tree per the IC specification.
// https://internetcomputer.org/docs/references/ic-interface-spec#certificate
pub const HashTree = union(enum) {
    empty,
    leaf: []const u8,
    labeled: Labeled,
    fork: Fork,
    pruned: Hash,

    pub const Labeled = struct { label: []const u8, child: *const HashTree };
    pub const Fork = struct { left: *const HashTree, right: *const HashTree };

    pub fn reconstruct(self: *const HashTree) Hash {
        switch (self.*) {
            .empty => {
                var h = Sha256.init(.{});
                h.update("\x11ic-hashtree-empty");
                return h.finalResult();
            },
            .leaf => |v| {
                var h = Sha256.init(.{});
                h.update("\x10ic-hashtree-leaf");
                h.update(v);
                return h.finalResult();
            },
            .labeled => |l| {
                const child_hash = l.child.reconstruct();
                var h = Sha256.init(.{});
                h.update("\x13ic-hashtree-labeled");
                h.update(l.label);
                h.update(&child_hash);
                return h.finalResult();
            },
            .fork => |f| {
                const left_hash = f.left.reconstruct();
                const right_hash = f.right.reconstruct();
                var h = Sha256.init(.{});
                h.update("\x10ic-hashtree-fork");
                h.update(&left_hash);
                h.update(&right_hash);
                return h.finalResult();
            },
            .pruned => |hash| return hash,
        }
    }

    // CBOR decoding for hash trees returned in IC certificates.
    // Encoding: Empty=[0], Fork=[1,l,r], Labeled=[2,label,t], Leaf=[3,v], Pruned=[4,h]
    pub fn decodeCbor(allocator: std.mem.Allocator, data: []const u8) !CborTree {
        return decodeCborNode(allocator, data);
    }

    fn decodeCborNode(allocator: std.mem.Allocator, data: []const u8) !CborTree {
        const decoded = try cbor.decodeValue(data);
        const content = switch (decoded.value) {
            .array => |c| c,
            else => return error.InvalidCbor,
        };

        const tag_result = try cbor.decodeValue(content);
        const node_tag = switch (tag_result.value) {
            .uint => |v| v,
            else => return error.InvalidCbor,
        };

        switch (node_tag) {
            0 => {
                const node = try allocator.create(HashTree);
                node.* = .{ .empty = {} };
                return .{ .allocator = allocator, .root = node };
            },
            1 => {
                var left = try decodeCborNode(allocator, tag_result.rest);
                errdefer left.deinit();
                const left_rest = skipCborNodeBytes(tag_result.rest) catch return error.InvalidCbor;
                var right = try decodeCborNode(allocator, left_rest);
                errdefer right.deinit();
                const node = try allocator.create(HashTree);
                node.* = .{ .fork = .{ .left = left.root.?, .right = right.root.? } };
                left.root = null;
                right.root = null;
                return .{ .allocator = allocator, .root = node };
            },
            2 => {
                const label_result = try cbor.decodeValue(tag_result.rest);
                const label = switch (label_result.value) {
                    .bytes => |b| b,
                    .text => |t| t,
                    else => return error.InvalidCbor,
                };
                var child = try decodeCborNode(allocator, label_result.rest);
                errdefer child.deinit();
                const node = try allocator.create(HashTree);
                node.* = .{ .labeled = .{ .label = label, .child = child.root.? } };
                child.root = null;
                return .{ .allocator = allocator, .root = node };
            },
            3 => {
                const val_result = try cbor.decodeValue(tag_result.rest);
                const val = switch (val_result.value) {
                    .bytes => |b| b,
                    .text => |t| t,
                    else => return error.InvalidCbor,
                };
                const node = try allocator.create(HashTree);
                node.* = .{ .leaf = val };
                return .{ .allocator = allocator, .root = node };
            },
            4 => {
                const hash_result = try cbor.decodeValue(tag_result.rest);
                const hash_bytes = switch (hash_result.value) {
                    .bytes => |b| b,
                    else => return error.InvalidCbor,
                };
                if (hash_bytes.len != 32) return error.InvalidCbor;
                const node = try allocator.create(HashTree);
                node.* = .{ .pruned = hash_bytes[0..32].* };
                return .{ .allocator = allocator, .root = node };
            },
            else => return error.InvalidCbor,
        }
    }

    fn skipCborNodeBytes(data: []const u8) ![]const u8 {
        const decoded = try cbor.decodeValue(data);
        return decoded.rest;
    }

    pub fn lookupPath(self: *const HashTree, path: []const []const u8) LookupResult {
        if (path.len == 0) {
            return switch (self.*) {
                .leaf => |v| .{ .found = v },
                .empty => .absent,
                .pruned => .unknown,
                .labeled => .unknown,
                .fork => .unknown,
            };
        }

        switch (self.*) {
            .labeled => |l| {
                if (std.mem.eql(u8, l.label, path[0])) {
                    return l.child.lookupPath(path[1..]);
                }
                return .absent;
            },
            .fork => |f| {
                const left = f.left.lookupPath(path);
                const right = f.right.lookupPath(path);
                return mergeLookups(left, right);
            },
            .pruned => return .unknown,
            .empty => return .absent,
            .leaf => return .absent,
        }
    }

    fn mergeLookups(a: LookupResult, b: LookupResult) LookupResult {
        switch (a) {
            .found => return a,
            .absent => return b,
            .unknown => return switch (b) {
                .found => b,
                else => .unknown,
            },
        }
    }
};

// Owns allocated HashTree nodes from CBOR decoding.
pub const CborTree = struct {
    allocator: std.mem.Allocator,
    root: ?*const HashTree,

    pub fn deinit(self: *CborTree) void {
        if (self.root) |r| freeTree(self.allocator, r);
    }

    fn freeTree(allocator: std.mem.Allocator, node: *const HashTree) void {
        switch (node.*) {
            .fork => |f| {
                freeTree(allocator, f.left);
                freeTree(allocator, f.right);
            },
            .labeled => |l| {
                freeTree(allocator, l.child);
            },
            else => {},
        }
        allocator.destroy(node);
    }
};

// IC spec example tree:
//   Fork(
//     Fork(
//       Labeled("a", Fork(
//         Fork(Labeled("x", Leaf("hello")), Empty),
//         Labeled("y", Leaf("world"))
//       )),
//       Labeled("b", Leaf("good"))
//     ),
//     Fork(
//       Labeled("c", Empty),
//       Labeled("d", Leaf("morning"))
//     )
//   )
fn specTestTree() HashTree {
    const empty: HashTree = .{ .empty = {} };
    const leaf_hello: HashTree = .{ .leaf = "hello" };
    const leaf_world: HashTree = .{ .leaf = "world" };
    const leaf_good: HashTree = .{ .leaf = "good" };
    const leaf_morning: HashTree = .{ .leaf = "morning" };

    const lx: HashTree = .{ .labeled = .{ .label = "x", .child = &leaf_hello } };
    const ly: HashTree = .{ .labeled = .{ .label = "y", .child = &leaf_world } };
    const lb: HashTree = .{ .labeled = .{ .label = "b", .child = &leaf_good } };
    const lc: HashTree = .{ .labeled = .{ .label = "c", .child = &empty } };
    const ld: HashTree = .{ .labeled = .{ .label = "d", .child = &leaf_morning } };

    const fork_lx_e: HashTree = .{ .fork = .{ .left = &lx, .right = &empty } };
    const a_child: HashTree = .{ .fork = .{ .left = &fork_lx_e, .right = &ly } };
    const la: HashTree = .{ .labeled = .{ .label = "a", .child = &a_child } };

    const left: HashTree = .{ .fork = .{ .left = &la, .right = &lb } };
    const right: HashTree = .{ .fork = .{ .left = &lc, .right = &ld } };

    return .{ .fork = .{ .left = &left, .right = &right } };
}

test "ic spec example tree root hash" {
    const tree = comptime specTestTree();
    const root = tree.reconstruct();
    const expected = @as(Hash, .{
        0xeb, 0x5c, 0x5b, 0x21, 0x95, 0xe6, 0x2d, 0x99,
        0x6b, 0x84, 0xc9, 0xbc, 0xc8, 0x25, 0x9d, 0x19,
        0xa8, 0x37, 0x86, 0xa2, 0xf5, 0x9e, 0x08, 0x78,
        0xce, 0xc8, 0x4c, 0x81, 0x1f, 0x66, 0x9a, 0xa0,
    });
    try std.testing.expectEqual(expected, root);
}

test "empty hash" {
    const tree: HashTree = .{ .empty = {} };
    const hash = tree.reconstruct();
    const expected = @as(Hash, .{
        0x4e, 0x3e, 0xd3, 0x5c, 0x4e, 0x2d, 0x1e, 0xe8,
        0x99, 0x96, 0x48, 0x3f, 0xb6, 0x26, 0x0a, 0x64,
        0xcf, 0xfb, 0x6c, 0x47, 0xdb, 0xab, 0x21, 0x6e,
        0x79, 0x30, 0xe8, 0x2f, 0x81, 0x90, 0xd1, 0x20,
    });
    try std.testing.expectEqual(expected, hash);
}

test "leaf hash" {
    const tree: HashTree = .{ .leaf = "hello" };
    const hash = tree.reconstruct();
    const expected = @as(Hash, .{
        0x99, 0xcf, 0x69, 0x44, 0x71, 0xb0, 0xe9, 0xc5,
        0x4d, 0xb3, 0x61, 0x20, 0xf9, 0x14, 0xf1, 0x25,
        0x37, 0xb3, 0xa7, 0x41, 0x7c, 0x30, 0x1e, 0x10,
        0x85, 0x1f, 0x34, 0x1f, 0x4d, 0x5c, 0xa1, 0x4a,
    });
    try std.testing.expectEqual(expected, hash);
}

test "labeled hash" {
    const leaf: HashTree = .{ .leaf = "hello" };
    const tree: HashTree = .{ .labeled = .{ .label = "x", .child = &leaf } };
    const hash = tree.reconstruct();
    const expected = @as(Hash, .{
        0x3b, 0x1f, 0x01, 0xd5, 0x75, 0x8c, 0xeb, 0x27,
        0x55, 0x46, 0x47, 0x65, 0x73, 0x0f, 0x27, 0x87,
        0xc2, 0xff, 0x0d, 0xf0, 0x03, 0xf8, 0x80, 0x89,
        0xd3, 0x0b, 0xaa, 0xda, 0x4f, 0x91, 0x56, 0x87,
    });
    try std.testing.expectEqual(expected, hash);
}

test "pruned passes through" {
    const h = @as(Hash, .{
        0xeb, 0x5c, 0x5b, 0x21, 0x95, 0xe6, 0x2d, 0x99,
        0x6b, 0x84, 0xc9, 0xbc, 0xc8, 0x25, 0x9d, 0x19,
        0xa8, 0x37, 0x86, 0xa2, 0xf5, 0x9e, 0x08, 0x78,
        0xce, 0xc8, 0x4c, 0x81, 0x1f, 0x66, 0x9a, 0xa0,
    });
    const tree: HashTree = .{ .pruned = h };
    try std.testing.expectEqual(h, tree.reconstruct());
}
