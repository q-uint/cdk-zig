const std = @import("std");

pub fn addCanister(
    b: *std.Build,
    dep: *std.Build.Dependency,
    name: []const u8,
) *std.Build.Step.Compile {
    const cdk_mod = dep.module("cdk");
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const root_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "cdk", .module = cdk_mod }},
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    return exe;
}

pub fn addTests(
    b: *std.Build,
    dep: *std.Build.Dependency,
) *std.Build.Step.Run {
    const pic_mod = dep.module("pocket-ic");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{
            .{ .name = "pocket-ic", .module = pic_mod },
        },
    });
    const t = b.addTest(.{ .root_module = test_mod });
    t.step.dependOn(b.getInstallStep());
    const run = b.addRunArtifact(t);
    const test_step = b.step("test", "Run e2e tests");
    test_step.dependOn(&run.step);
    return run;
}

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
        "src/stable/stable.zig",
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
