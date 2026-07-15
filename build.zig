const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Required by std.c calls and explicit for cross-release builds.
        .link_libc = true,
    });

    // Single-source the version: read it from build.zig.zon and expose it to
    // the program as `build_options.version`. The exe, test, and check targets
    // all share `root_module`, so attaching here covers all three.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "fable-monitor",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // `zig build run` — build and run a single poll.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the monitor once");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — run the unit tests in src/main.zig.
    const unit_tests = b.addTest(.{ .root_module = root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build check` — type-check without emitting a binary (fast feedback,
    // and what an editor/LSP wants to drive).
    const check = b.addExecutable(.{
        .name = "fable-monitor",
        .root_module = root_module,
    });
    const check_step = b.step("check", "Type-check without installing");
    check_step.dependOn(&check.step);
}
