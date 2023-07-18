const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const ClassError = error{
    AddIvarToClassFailure,
    AddMethodToClassFailure,
};

pub const Class = struct {
    value: c.Class,

    pub usingnamespace MsgSend(Class);

    /// Creates a new class with a given name derived from an optional superclass.
    /// The "ivars" arg is an array of structs with "name" and "ivar_type" fields. Allows addition of ivars to the class
    /// The "methods" is an array of structs with "name" and "function" fields. Allows addition of instance methods on the class
    /// Registers the class before returning
    pub fn new(name: [:0]const u8, superclass: ?Class, ivars: anytype, methods: anytype) !?Class {
        const new_class = c.objc_allocateClassPair(superclass.?.value orelse null, name.ptr, 0) orelse return null;
        errdefer c.objc_disposeClassPair(new_class);

        // add ivars
        inline for (ivars) |ivar| {
            try addIvar(new_class, ivar.name, ivar.ivar_type);
        }

        // add methods
        inline for (methods) |method| {
            try addInstanceMethod(new_class, method.name, @TypeOf(method.function), method.function);
        }

        // registers a class pair. Must happen for the class to be recognized by the runtime
        c.objc_registerClassPair(new_class);

        return Class{
            .value = new_class,
        };
    }

    /// Returns the class definition of a specified class.
    pub fn getClass(name: [:0]const u8) ?Class {
        return Class{
            .value = c.objc_getClass(name.ptr) orelse return null,
        };
    }

    /// Returns a property with a given name of a given class.
    pub fn getProperty(self: Class, name: [:0]const u8) ?objc.Property {
        return objc.Property{
            .value = c.class_getProperty(self.value, name.ptr) orelse return null,
        };
    }

    /// Describes the properties declared by a class. This must be freed.
    pub fn copyPropertyList(self: Class) []objc.Property {
        var count: c_uint = undefined;
        const list = @as([*c]objc.Property, @ptrCast(c.class_copyPropertyList(self.value, &count)));
        if (count == 0) return list[0..0];
        return list[0..count];
    }

    // Adds an instance variable to a class. This must be called after objc_allocateClassPair and before objc_RegisterClassPair
    fn addIvar(class: c.Class, name: [:0]const u8, comptime IvarType: type) !void {
        var buf: [100]u8 = undefined;
        const ivar_encoding = try std.fmt.bufPrint(&buf, "{s}", .{objc.Encoding.newFromType(IvarType)});

        const result = c.class_addIvar(
            class,
            name,
            @sizeOf(IvarType),
            @alignOf(IvarType),
            ivar_encoding.ptr
        );
        
        // aarch64 turns the BOOL type into an actual zig 'bool', while x86_64 keeps it at an i8
        const success = switch (builtin.target.cpu.arch) {
            .aarch64 => result,
            .x86_64 => result != 0,
            else => @compileError("unsupported objc architecture")
        };
        
        if (!success) return ClassError.AddIvarToClassFailure;
    }

    // Adds an instance method to a class. This must be called after objc_allocateClassPair and before objc_RegisterClassPair
    fn addInstanceMethod(class: c.Class, name: [:0]const u8, comptime FnType: type, func_impl: FnType) anyerror!void {
        var buf: [100]u8 = undefined;
        const method_encoding = try std.fmt.bufPrint(&buf, "{s}", .{objc.Encoding.newFromType(FnType)});
        const method_sel = objc.sel(name);
        const result = c.class_addMethod(
            class,
            method_sel.value,
            @as(*const fn() callconv(.C) void, @ptrCast(&func_impl)),
            method_encoding.ptr
        );

        // aarch64 turns the BOOL type into an actual zig 'bool', while x86_64 keeps it at an i8
        const success = switch (builtin.target.cpu.arch) {
            .aarch64 => result,
            .x86_64 => result != 0,
            else => @compileError("unsupported objc architecture")
        };

        if (!success) return ClassError.AddMethodToClassFailure;
    }

    fn register(self: Class) void {
        c.objc_registerClassPair(self.value);
    }
};

test "new" {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject");
    try testing.expect(NSObject != null);

    // function added to new class
    const TestFn = struct {
        fn add(_: c.id, _: c.SEL, a: c_int, b: c_int) callconv(.C) c_int {
            return a + b;
        }
    };

    // Init new class and test if it has an NSObject superclass property on it
    const TestClass = try Class.new("TestClass",
        NSObject.?,
        .{
            .{ .name = "test_var", .ivar_type = c_int }
        },
        .{
            .{ .name = "add", .function = TestFn.add }
        }
    );  

    // Test if className property is on the class
    try testing.expect(TestClass.?.getProperty("className") != null);

    // Allocate TestClass, call add method 1 + 2, expect 3, deallocate object
    const obj = TestClass.?.msgSend(objc.Object, objc.sel("alloc"), .{});
    const sum = obj.msgSend(c_int, objc.sel("add"), .{ @as(c_int, 1), @as(c_int, 2) });
    defer obj.msgSend(void, objc.sel("dealloc"), .{});
    try testing.expectEqual(@as(c_int, 3), sum);
}

test "getClass" {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject");
    try testing.expect(NSObject != null);
    try testing.expect(Class.getClass("NoWay") == null);
}

test "msgSend" {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject").?;

    // Should work with primitives
    const id = NSObject.msgSend(c.id, objc.Sel.registerName("alloc"), .{});
    try testing.expect(id != null);
    {
        const obj: objc.Object = .{ .value = id };
        obj.msgSend(void, objc.sel("dealloc"), .{});
    }

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    obj.msgSend(void, objc.sel("dealloc"), .{});
}

test "getProperty" {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject").?;

    try testing.expect(NSObject.getProperty("className") != null);
    try testing.expect(NSObject.getProperty("nope") == null);
}

test "copyProperyList" {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject").?;

    const list = NSObject.copyPropertyList();
    defer objc.free(list);
    try testing.expect(list.len > 20);
}
