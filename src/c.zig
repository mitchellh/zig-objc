pub const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

/// On some targets, Objective-C uses `i8` instead of `bool`.
/// This helper casts a target value type to `bool`.
pub fn boolResult(result: c.BOOL) bool {
    return switch (c.BOOL) {
        bool => result,
        i8 => result == 1,
        else => @compileError("unexpected boolean type"),
    };
}

/// On some targets, Objective-C uses `i8` instead of `bool`.
/// This helper casts a `bool` value to the target value type.
pub fn boolParam(param: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => param,
        i8 => @intFromBool(param),
        else => @compileError("unexpected boolean type"),
    };
}
