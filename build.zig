const std = @import("std");

pub const CanisterOptions = struct {
    wasm64: bool = false,
    root_source_file: ?[]const u8 = null,
};

pub fn addCanister(
    b: *std.Build,
    dep: *std.Build.Dependency,
    name: []const u8,
    options: CanisterOptions,
) *std.Build.Step.Compile {
    const cdk_mod = dep.module("cdk");
    const target = b.resolveTargetQuery(.{
        .cpu_arch = if (options.wasm64) .wasm64 else .wasm32,
        .os_tag = .freestanding,
    });
    const root_mod = b.createModule(.{
        .root_source_file = b.path(options.root_source_file orelse b.fmt("{s}.zig", .{name})),
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
    const cdk_mod = dep.module("cdk");
    const pic_mod = dep.module("pocket-ic");
    const bls_mod = dep.module("bls");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{
            .{ .name = "cdk", .module = cdk_mod },
            .{ .name = "pocket-ic", .module = pic_mod },
            .{ .name = "bls", .module = bls_mod },
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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cdk_mod = b.addModule("cdk", .{
        .root_source_file = b.path("src/cdk.zig"),
    });

    const blst_dep_lib = b.dependency("blst", .{});
    const bls_mod_lib = b.addModule("bls", .{
        .root_source_file = b.path("src/bls.zig"),
    });
    linkBlst(b, bls_mod_lib, blst_dep_lib, target, optimize);

    _ = b.addModule("pocket-ic", .{
        .root_source_file = b.path("src/pocket_ic.zig"),
        .imports = &.{
            .{ .name = "cdk", .module = cdk_mod },
            .{ .name = "bls", .module = bls_mod_lib },
        },
    });

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/base32.zig",
        "src/principal.zig",
        "src/pocket_ic.zig",
        "src/stable/stable.zig",
        "src/candid_tests.zig",
        "src/cbor.zig",
        "src/hash_tree.zig",
    };
    for (test_files) |file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        if (std.mem.eql(u8, file, "src/pocket_ic.zig")) {
            mod.addImport("cdk", cdk_mod);
        }
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // BLS tests require linking blst C library (native only).
    const blst_dep = b.dependency("blst", .{});
    {
        const bls_mod = b.createModule(.{
            .root_source_file = b.path("src/bls.zig"),
            .target = target,
            .optimize = optimize,
        });
        linkBlst(b, bls_mod, blst_dep, target, optimize);
        bls_mod.linkSystemLibrary("c", .{});
        const bls_test = b.addTest(.{ .root_module = bls_mod });
        test_step.dependOn(&b.addRunArtifact(bls_test).step);
    }

    const e2e_step = b.step("e2e", "Run e2e tests for all examples");
    for (examples) |name| {
        const run = b.addSystemCommand(&.{ "zig", "build", "test" });
        run.setCwd(b.path(b.fmt("examples/{s}", .{name})));
        e2e_step.dependOn(&run.step);
    }
}

// blst ships no Zig bindings. Zig 0.17 removed `@cImport`, so the header is
// translated once as a build step and imported as a plain module named "c".
// Translation is pinned to one target here, rather than following each
// consumer's target as `@cImport` did; bls is only ever built natively.
fn linkBlst(
    b: *std.Build,
    mod: *std.Build.Module,
    blst: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) void {
    const translated = b.addTranslateC(.{
        .root_source_file = blst.path("bindings/blst.h"),
        .target = target,
        .optimize = optimize,
    });
    translated.addIncludePath(blst.path("bindings"));
    mod.addImport("c", translated.createModule());

    mod.addIncludePath(blst.path("bindings"));
    mod.addCSourceFile(.{
        .file = blst.path("src/server.c"),
        .flags = &.{ "-fno-builtin", "-Wno-unused-function" },
    });
    mod.addCSourceFile(.{
        .file = blst.path("build/assembly.S"),
        .flags = &.{},
    });
}

// Examples with an e2e suite, listed explicitly so that a missing or
// misnamed directory is a build error rather than a silently skipped test.
const examples = [_][]const u8{
    "call",
    "candid",
    "certified_data",
    "profiling",
    "stable",
    "timers",
};
