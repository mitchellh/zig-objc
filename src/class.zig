const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Class = struct {
    value: c.Class,

    pub usingnamespace MsgSend(Class);

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
        const list = @ptrCast([*c]objc.Property, c.class_copyPropertyList(self.value, &count));
        if (count == 0) return list[0..0];
        return list[0..count];
    }
};

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
