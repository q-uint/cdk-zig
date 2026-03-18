const std = @import("std");

pub const std_encoding = Encoding.init();

pub const Encoding = struct {
    encode_map: [32]u8,
    decode_map: [256]u8,

    pub fn init() Encoding {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        return Encoding{
            .encode_map = blk: {
                var a = [_]u8{0xFF} ** 32;
                for (alphabet, 0..) |c, i| {
                    a[i] = c;
                }
                break :blk a;
            },
            .decode_map = blk: {
                var a = [_]u8{0xFF} ** 256;
                for (alphabet, 0..) |c, i| {
                    a[@intCast(c)] = @intCast(i);
                }
                break :blk a;
            },
        };
    }

    pub fn encode(
        self: Encoding,
        dst: []u8,
        src: []const u8,
    ) void {
        if (src.len == 0) {
            return;
        }

        var dst_i: usize = 0;
        var src_i: usize = 0;
        const n = (src.len / 5) * 5;
        while (src_i < n) {
            const hi: u32 = @as(u32, src[src_i + 0]) << 24 | @as(u32, src[src_i + 1]) << 16 | @as(u32, src[src_i + 2]) << 8 | @as(u32, src[src_i + 3]);
            const lo: u32 = hi << 8 | @as(u32, src[src_i + 4]);

            dst[dst_i + 0] = self.encode_map[hi >> 27 & 0x1F];
            dst[dst_i + 1] = self.encode_map[hi >> 22 & 0x1F];
            dst[dst_i + 2] = self.encode_map[hi >> 17 & 0x1F];
            dst[dst_i + 3] = self.encode_map[hi >> 12 & 0x1F];
            dst[dst_i + 4] = self.encode_map[hi >> 7 & 0x1F];
            dst[dst_i + 5] = self.encode_map[hi >> 2 & 0x1F];
            dst[dst_i + 6] = self.encode_map[lo >> 5 & 0x1F];
            dst[dst_i + 7] = self.encode_map[lo & 0x1F];

            src_i += 5;
            dst_i += 8;
        }

        const r = src.len - src_i;
        if (r == 0) {
            return;
        }

        var v: u32 = 0;
        if (r >= 4) {
            v |= @as(u32, src[src_i + 3]);
            dst[dst_i + 6] = self.encode_map[v << 3 & 0x1F];
            dst[dst_i + 5] = self.encode_map[v >> 2 & 0x1F];
        }
        if (r >= 3) {
            v |= @as(u32, src[src_i + 2]) << 8;
            dst[dst_i + 4] = self.encode_map[v >> 7 & 0x1F];
        }
        if (r >= 2) {
            v |= @as(u32, src[src_i + 1]) << 16;
            dst[dst_i + 3] = self.encode_map[v >> 12 & 0x1F];
            dst[dst_i + 2] = self.encode_map[v >> 17 & 0x1F];
        }
        if (r >= 1) {
            v |= @as(u32, src[src_i + 0]) << 24;
            dst[dst_i + 1] = self.encode_map[v >> 22 & 0x1F];
            dst[dst_i + 0] = self.encode_map[v >> 27 & 0x1F];
        }
    }
};

pub fn decode_len(n: usize) usize {
    return n * 5 / 8;
}

pub const DecodeError = error{InvalidCharacter};

pub fn decode(dst: []u8, src: []const u8) DecodeError!usize {
    var bits: usize = 0;
    var buffer: u32 = 0;
    var di: usize = 0;
    for (src) |c| {
        const val: u5 = switch (c) {
            'A'...'Z' => @intCast(c - 'A'),
            'a'...'z' => @intCast(c - 'a'),
            '2'...'7' => @intCast(c - '2' + 26),
            '-' => continue,
            else => return error.InvalidCharacter,
        };
        buffer = (buffer << 5) | val;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            dst[di] = @intCast((buffer >> @intCast(bits)) & 0xFF);
            di += 1;
        }
    }
    return di;
}

pub fn encode_len(n: usize) usize {
    return n / 5 * 8 + (n % 5 * 8 + 4) / 5;
}

test "std_encoding" {
    const TestPair = struct {
        decoded: []const u8,
        encoded: []const u8,
    };
    const pairs = [_]TestPair{
        TestPair{ .decoded = "", .encoded = "" },
        TestPair{ .decoded = "f", .encoded = "MY" },
        TestPair{ .decoded = "fo", .encoded = "MZXQ" },
        TestPair{ .decoded = "foo", .encoded = "MZXW6" },
        TestPair{ .decoded = "foob", .encoded = "MZXW6YQ" },
        TestPair{ .decoded = "fooba", .encoded = "MZXW6YTB" },
        TestPair{ .decoded = "foobar", .encoded = "MZXW6YTBOI" },
    };
    for (pairs) |tp| {
        const encoded_len = encode_len(tp.decoded.len);
        const encoded = std.heap.page_allocator.alloc(u8, @intCast(encoded_len)) catch @panic("");
        defer std.heap.page_allocator.free(encoded);
        std_encoding.encode(encoded, tp.decoded);
        try std.testing.expectEqualSlices(u8, encoded, tp.encoded);
    }
}
