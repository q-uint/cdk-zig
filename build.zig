const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("cdk", .{
        .root_source_file = b.path("src/cdk.zig"),
    });

    _ = b.addModule("pocket-ic", .{
        .root_source_file = b.path("src/pocket_ic.zig"),
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/base32.zig",
        "src/principal.zig",
        "src/pocket_ic.zig",
    };
    for (test_files) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const e2e_step = b.step("e2e", "Run e2e tests for all examples");
    var examples_dir = std.fs.openDirAbsolute(
        b.pathFromRoot("examples"),
        .{ .iterate = true },
    ) catch return;
    defer examples_dir.close();
    var it = examples_dir.iterate();
    while (it.next() catch return) |entry| {
        if (entry.kind != .directory) continue;
        const dir = b.fmt("examples/{s}", .{entry.name});
        const run = b.addSystemCommand(&.{ "zig", "build", "test" });
        run.setCwd(b.path(dir));
        e2e_step.dependOn(&run.step);
    }
}
