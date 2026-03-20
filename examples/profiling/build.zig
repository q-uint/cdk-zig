const cdk = @import("cdk");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("cdk", .{});
    _ = cdk.addCanister(b, dep, "profiling", .{});
    const run_tests = cdk.addTests(b, dep);

    // Generate flamegraph SVGs from folded stacks produced by tests.
    const flamegraph_step = b.step("flamegraph", "Generate flamegraph SVGs");
    const folded_files = [_]struct { []const u8, []const u8 }{
        .{ "profile.folded", "../../../examples/profiling/profile.svg" },
        .{ "stable.folded", "../../../examples/profiling/stable.svg" },
        .{ "heap.folded", "../../../examples/profiling/heap.svg" },
    };
    for (folded_files) |entry| {
        const fg = b.addSystemCommand(&.{ "flamegraph.pl", entry[0] });
        fg.step.dependOn(&run_tests.step);
        fg.setCwd(b.path("."));
        const svg = fg.captureStdOut();
        const install_svg = b.addInstallFile(svg, entry[1]);
        flamegraph_step.dependOn(&install_svg.step);
    }
}
