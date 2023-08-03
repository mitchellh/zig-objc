const std = @import("std");
const xcode_frameworks = @import("xcode_frameworks");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("objc", .{ .source_file = .{ .path = "src/main.zig" } });

    const tests = b.addTest(.{
        .name = "objc-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.linkSystemLibrary("objc");
    try xcode_frameworks.addPaths(b, tests);
    b.installArtifact(tests);

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);
}
