const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const add_paths = b.option(
        bool,
        "add-paths",
        "add apple SDK paths from Xcode installation",
    ) orelse true;

    // Translate the Objective-C runtime headers once in the build so the Zig
    // code can import a stable generated module instead of invoking @cImport
    // from every compile.
    const objc_c = try translateCModule(b, target, optimize);

    const objc = b.addModule("objc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    objc.addImport("objc-c", objc_c);
    if (add_paths) try addAppleSDK(b, objc);
    objc.linkSystemLibrary("objc", .{});
    objc.linkFramework("Foundation", .{});

    const tests_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_root.addImport("objc-c", objc_c);
    const tests = b.addTest(.{
        .name = "objc-test",
        .root_module = tests_root,
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

/// Returns a translated Objective-C header module built from the Apple SDK.
///
/// This patches the single `objc/runtime.h` declaration that currently breaks
/// Zig 0.16 `translate-c`, then translates `objc/runtime.h` and
/// `objc/message.h` into an importable Zig module. Bug report:
/// https://codeberg.org/ziglang/zig/issues/31917
fn translateCModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Module {
    const sdk_path = try appleSDKPath(b, target);
    const include_path = b.pathJoin(&.{ sdk_path, "/usr/include" });
    const runtime_path = b.pathJoin(&.{ include_path, "/objc/runtime.h" });
    const runtime_h = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        runtime_path,
        b.allocator,
        .limited(1024 * 1024),
    );

    // Zig 0.16's translate-c cannot parse Clang block declarators (`^`) in
    // objc/runtime.h. Patch just the offending declaration so we still
    // translate the real Apple headers rather than maintaining a local shim.
    const needle =
        \\objc_enumerateClasses(const void * _Nullable image,
        \\                      const char * _Nullable namePrefix,
        \\                      Protocol * _Nullable conformingTo,
        \\                      Class _Nullable subclassing,
        \\                      void (^ _Nonnull block)(Class _Nonnull aClass, BOOL * _Nonnull stop)
        \\                      OBJC_NOESCAPE)
    ;
    // Fail loudly if Apple changes the declaration so we don't silently stop
    // patching the one line this workaround depends on.
    if (std.mem.indexOf(u8, runtime_h, needle) == null) {
        return error.ObjCRuntimeHeaderChanged;
    }

    const patched_runtime_h = try std.mem.replaceOwned(u8, b.allocator, runtime_h, needle,
        \\objc_enumerateClasses(const void * _Nullable image,
        \\                      const char * _Nullable namePrefix,
        \\                      Protocol * _Nullable conformingTo,
        \\                      Class _Nullable subclassing,
        \\                      void * _Nonnull block)
    );

    const wf = b.addWriteFiles();
    _ = wf.add("objc/runtime.h", patched_runtime_h);
    const import_h = wf.add("objc-import.h",
        \\#include <objc/runtime.h>
        \\#include <objc/message.h>
        \\
    );

    const c = b.addTranslateC(.{
        .root_source_file = import_h,
        .target = target,
        .optimize = optimize,
    });
    // Search the generated directory first so <objc/runtime.h> resolves to the
    // patched copy, while every other include still falls through to the SDK.
    c.addIncludePath(wf.getDirectory());
    c.addSystemIncludePath(.{ .cwd_relative = include_path });
    return c.createModule();
}

/// Add the SDK framework, include, and library paths to the given module.
/// The module target is used to determine the SDK to use so it must have
/// a resolved target.
///
/// The Apple SDK is determined based on the build target and found using
/// xcrun, so it requires a valid Xcode installation.
pub fn addAppleSDK(b: *std.Build, m: *std.Build.Module) !void {
    const path = try appleSDKPath(b, m.resolved_target.?);
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}

fn appleSDKPath(b: *std.Build, target: std.Build.ResolvedTarget) ![]const u8 {
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

    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.result.cpu.arch,
        .os = target.result.os.tag,
        .abi = target.result.abi,
    });

    // This executes `xcrun` to get the SDK path. We don't want to execute
    // this multiple times so we cache the value.
    if (!gop.found_existing) {
        gop.value_ptr.* = std.zig.system.darwin.getSdk(
            b.allocator,
            b.graph.io,
            &target.result,
        );
    }

    // The active SDK we want to use
    return gop.value_ptr.* orelse switch (target.result.os.tag) {
        // Return a more descriptive error. Before we just returned the
        // generic error but this was confusing a lot of community members.
        // It costs us nothing in the build script to return something better.
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };
}
