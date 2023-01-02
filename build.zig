const std = @import("std");
const system_sdk = @import("vendor/mach/libs/glfw/system_sdk.zig");

/// Use this with addPackage in your project.
pub const pkg = std.build.Pkg{
    .name = "objc",
    .source = .{ .path = thisDir() ++ "/src/main.zig" },
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const tests = b.addTestExe("objc-test", "src/main.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    tests.linkSystemLibrary("objc");
    system_sdk.include(b, tests, .{});
    tests.install();

    const test_step = b.step("test", "Run tests");
    const tests_run = tests.run();
    test_step.dependOn(&tests_run.step);
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
