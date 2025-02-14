# zig-objc - Objective-C Runtime Bindings for Zig

zig-objc allows Zig to call Objective-C using the macOS
[Objective-C runtime](https://developer.apple.com/documentation/objectivec/objective-c_runtime?language=objc).

**Project Status:** This library does not currently have 100% coverage over the Objective-C
runtime, but supports enough features to be useful. I use this library in
shipping code that I run every day.

## Features

  * Classes:
    - Find classes
    - Read property metadata
    - Call methods
    - Create subclasses
    - Add methods
    - Replace methods
    - Add instance variables
  * Objects:
    - Class or class name for object
    - Read and write properties
    - Read and write instance variables
    - Call methods
    - Call superclass methods
  * Protocols:
    - Check conformance
    - Read property metadata
  * Blocks:
    - Define and invoke blocks with captured values
    - Pass blocks to C APIs which can then invoke your Zig code
  * Autorelease pools

There is still a bunch of the runtime API that isn't supported. It wouldn't
be hard work to add it, I just haven't needed it. For example: object
instance variables, protocols, dynamically registering new classes, etc.

Feel free to open a pull request if you want additional features.
**Do not open issues to request features (only pull requests).** I'm
only going to add features I need, _unless_ you open a pull request to
add it yourself.

## Example

Here is an example that uses `NSProcessInfo` to implement a function
`macosVersionAtLeast` that returns true if the running macOS versions
is at least the given arguments.

```zig
const objc = @import("objc");

pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    /// Get the objc class from the runtime
    const NSProcessInfo = objc.getClass("NSProcessInfo").?;

    /// Call a class method with no arguments that returns another objc object.
    const info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    /// Call an instance method that returns a boolean and takes a single
    /// argument.
    return info.msgSend(bool, "isOperatingSystemAtLeastVersion:", .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

/// This extern struct matches the Cocoa headers for layout.
const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};
```

## Usage

Add this repository to your `build.zig.zon` file. Then:

```zig
pub fn build(b: *std.build.Builder) !void {
  // ... other stuff

  exe.root_module.addImport("objc", b.dependency("zig_objc", .{
    .target = target,
    .optimize = optimize,
  }).module("objc"));
}
```

Note that `zig-objc` will find and link to headers from the target SDK
(macOS, iOS, etc.) automatically by finding your Xcode installation. If
Xcode is not installed, you can add it manually but you must set the
`-Dadd-paths=false` flag.

**`zig-objc` only works with released versions of Zig.** We don't support
nightly versions because the Zig compiler is still changing too much.

## Documentation

Read the source code, it is well commented. If something isn't clear, please
open an issue and I'll enhance the source code. Some familiarity with
Objective-C concepts is expected for understanding the doc comments.
