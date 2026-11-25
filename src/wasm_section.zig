//! Build tool: copies a wasm module with a custom section appended.
//!
//!     wasm_section <in.wasm> <out.wasm> <section name> <contents>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.Usage;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const module = try cwd.readFileAlloc(io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(module);

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    try out.writer.writeAll(module);
    try appendSection(&out.writer, args[3], args[4]);

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

// Section id 0, the payload size, then the name and contents.
fn appendSection(w: *std.Io.Writer, name: []const u8, contents: []const u8) !void {
    const name_len: u32 = @intCast(name.len);
    var len_buf: [5]u8 = undefined;
    var len_w: std.Io.Writer = .fixed(&len_buf);
    try len_w.writeUleb128(name_len);
    const size: u32 = @intCast(len_w.buffered().len + name.len + contents.len);

    try w.writeByte(0);
    try w.writeUleb128(size);
    try w.writeUleb128(name_len);
    try w.writeAll(name);
    try w.writeAll(contents);
}

test appendSection {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try appendSection(&w, "ab", "xyz");
    try std.testing.expectEqualSlices(u8, &.{ 0, 6, 2, 'a', 'b', 'x', 'y', 'z' }, w.buffered());
}
