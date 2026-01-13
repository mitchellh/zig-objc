const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const add_paths = b.option(
        bool,
        "add-paths",
        "add apple SDK paths from Xcode installation",
    ) orelse true;

    const objc = b.addModule("objc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (add_paths) try addAppleSDK(b, objc);
    objc.linkSystemLibrary("objc", .{});
    objc.linkFramework("Foundation", .{});

    const tests = b.addTest(.{
        .name = "objc-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkSystemLibrary("objc", .{});
    tests.root_module.linkFramework("Foundation", .{});
    tests.root_module.linkFramework("AppKit", .{}); // Required by 'tagged pointer' test.
    try addAppleSDK(b, tests.root_module);
    b.installArtifact(tests);

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);
}

/// Add the SDK framework, include, and library paths to the given module.
/// The module target is used to determine the SDK to use so it must have
/// a resolved target.
///
/// The Apple SDK is determined based on the build target and found using
/// xcrun, so it requires a valid Xcode installation.
pub fn addAppleSDK(b: *std.Build, m: *std.Build.Module) !void {
    // The cache. This always uses b.allocator and never frees memory
    // (which is idiomatic for a Zig build exe).
    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            os: std.Target.Os.Tag,
            abi: std.Target.Abi,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?[]const u8) = .{};
    };

    const target = m.resolved_target.?.result;
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });

    // This executes `xcrun` to get the SDK path. We don't want to execute
    // this multiple times so we cache the value.
    if (!gop.found_existing) {
        gop.value_ptr.* = std.zig.system.darwin.getSdk(
            b.allocator,
            b.graph.io,
            &m.resolved_target.?.result,
        );
    }

    // The active SDK we want to use
    const path = gop.value_ptr.* orelse return switch (target.os.tag) {
        // Return a more descriptive error. Before we just returned the
        // generic error but this was confusing a lot of community members.
        // It costs us nothing in the build script to return something better.
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}
