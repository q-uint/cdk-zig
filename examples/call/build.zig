const std = @import("std");

const canisters: []const []const u8 = &.{ "callee", "caller" };

pub fn build(b: *std.Build) void {
    const cdk_dep = b.dependency("cdk", .{});
    const cdk_mod = cdk_dep.module("cdk");

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    inline for (canisters) |name| {
        const root_mod = b.createModule(.{
            .root_source_file = b.path(name ++ ".zig"),
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
        b.step(name, "Build the " ++ name ++ " canister").dependOn(&install.step);
    }
}
