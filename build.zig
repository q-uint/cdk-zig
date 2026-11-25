const std = @import("std");

const version = @import("build.zig.zon").version;

pub const principal = @import("src/principal.zig");

pub const CanisterOptions = struct {
    wasm64: bool = false,
    root_source_file: ?[]const u8 = null,
    /// Also build `{name}_profiling.wasm`, the same canister with profiling
    /// on.
    profiling: bool = false,
    /// Also build `{name}_inspect.wasm`, exposing the root's `pub` stable
    /// logs read-only.
    inspect: bool = false,
    /// Who may call the `__` endpoints of the profiling and inspect builds.
    dev_access: DevAccess = .controllers,
};

pub const DevAccess = union(enum) {
    /// The canister's controllers.
    controllers,
    /// Anyone, for a local replica or PocketIC.
    anyone,
    /// The controllers and these principals, e.g.
    /// `&.{cdk.principal.comptimeFromText("2vxsx-fae")}`.
    principals: []const principal.Principal,
};

/// How a wasm was built. Each carries it in a `cdk:build` section.
pub const Metadata = struct {
    version: []const u8 = version,
    profiling: bool = false,
    inspect: bool = false,
    dev_access: DevAccess = .controllers,
};

/// Returns the plain canister's `*Compile`, also with `.profiling` or
/// `.inspect`.
///
/// Each wasm carries its `Metadata` as JSON in a private `cdk:build` section.
/// Controllers read it from `read_state` at `/canister/<id>/metadata/cdk:build`.
pub fn addCanister(
    b: *std.Build,
    dep: *std.Build.Dependency,
    name: []const u8,
    options: CanisterOptions,
) *std.Build.Step.Compile {
    const source = options.root_source_file orelse b.fmt("{s}.zig", .{name});
    const plain: Metadata = .{ .dev_access = options.dev_access };
    const exe = addWasm(b, dep, dep.module("cdk"), name, source, options.wasm64, plain);
    if (options.profiling) {
        const variant: Metadata = .{ .profiling = true, .dev_access = options.dev_access };
        addVariant(b, dep, b.fmt("{s}_profiling", .{name}), source, options.wasm64, variant);
    }
    if (options.inspect) {
        const variant: Metadata = .{ .inspect = true, .dev_access = options.dev_access };
        addVariant(b, dep, b.fmt("{s}_inspect", .{name}), source, options.wasm64, variant);
    }
    return exe;
}

// The cdk module is shared, so a variant gets its own copy reading a
// different cdk_build_options.
fn addVariant(
    b: *std.Build,
    dep: *std.Build.Dependency,
    name: []const u8,
    source: []const u8,
    wasm64: bool,
    variant: Metadata,
) void {
    const cdk_mod = b.createModule(.{
        .root_source_file = dep.path("src/cdk.zig"),
        .imports = &.{.{ .name = "cdk_build_options", .module = buildOptions(b, variant) }},
    });
    _ = addWasm(b, dep, cdk_mod, name, source, wasm64, variant);
}

fn buildOptions(b: *std.Build, variant: Metadata) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", variant.version);
    options.addOption(bool, "profiling", variant.profiling);
    options.addOption(bool, "inspect", variant.inspect);
    options.addOption(bool, "dev_access_anyone", variant.dev_access == .anyone);
    // Each principal's bytes, rebuilt with Principal.from in the cdk.
    var principals: std.ArrayList([]const u8) = .empty;
    if (variant.dev_access == .principals) {
        for (variant.dev_access.principals) |*p| {
            principals.append(b.allocator, p.slice()) catch @panic("OOM");
        }
    }
    options.addOption([]const []const u8, "dev_access_principals", principals.items);
    return options.createModule();
}

fn addWasm(
    b: *std.Build,
    dep: *std.Build.Dependency,
    cdk_mod: *std.Build.Module,
    name: []const u8,
    source: []const u8,
    wasm64: bool,
    variant: Metadata,
) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = if (wasm64) .wasm64 else .wasm32,
        .os_tag = .freestanding,
    });
    const root_mod = b.createModule(.{
        .root_source_file = b.path(source),
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

    const file = b.fmt("{s}.wasm", .{name});
    const section = b.addRunArtifact(dep.artifact("wasm_section"));
    section.addFileArg(exe.getEmittedBin());
    const with_section = section.addOutputFileArg(file);
    section.addArg("icp:private cdk:build");
    const json = std.json.Stringify.valueAlloc(b.allocator, variant, .{}) catch @panic("OOM");
    section.addArg(json);

    const install = b.addInstallBinFile(with_section, file);
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

    const default_options = buildOptions(b, .{});
    const cdk_mod = b.addModule("cdk", .{
        .root_source_file = b.path("src/cdk.zig"),
        .imports = &.{.{ .name = "cdk_build_options", .module = default_options }},
    });

    // Appends the cdk:build section in addCanister.
    b.installArtifact(b.addExecutable(.{
        .name = "wasm_section",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_section.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));

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
        "src/allocator.zig",
        "src/base32.zig",
        "src/principal.zig",
        "src/pocket_ic.zig",
        "src/stable/stable.zig",
        "src/candid_tests.zig",
        "src/cbor.zig",
        "src/hash_tree.zig",
        "src/inspect.zig",
        "src/wasm_section.zig",
    };
    for (test_files) |file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            // Any file reaching allocator.zig reaches profiling.zig.
            .imports = &.{.{ .name = "cdk_build_options", .module = default_options }},
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

    const e2e_step = b.step("e2e", "Run e2e tests for all examples and test suites");
    for (examples) |name| {
        const run = b.addSystemCommand(&.{ "zig", "build", "test" });
        run.setCwd(b.path(b.fmt("examples/{s}", .{name})));
        e2e_step.dependOn(&run.step);
    }
    for (suites) |name| {
        const run = b.addSystemCommand(&.{ "zig", "build", "test" });
        run.setCwd(b.path(b.fmt("tests/{s}", .{name})));
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
    "inspect",
    "json",
    "profiling",
    "stable",
    "timers",
};

// Canisters built only to test the CDK, under tests/.
const suites = [_][]const u8{
    "call",
};
