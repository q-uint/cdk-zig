const std = @import("std");

pub fn build(b: *std.Build) void {
    const cdk_dep = b.dependency("cdk", .{});
    const cdk_mod = cdk_dep.module("cdk");

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("stable.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "cdk", .module = cdk_mod }},
    });
    const exe = b.addExecutable(.{
        .name = "stable",
        .root_module = root_mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // E2E tests
    const pic_mod = cdk_dep.module("pocket-ic");
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
    const test_step = b.step("test", "Run e2e tests");
    test_step.dependOn(&b.addRunArtifact(t).step);
}
