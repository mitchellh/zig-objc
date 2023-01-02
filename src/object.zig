const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    pub usingnamespace MsgSend(Object);

    pub fn fromId(id: anytype) Object {
        return .{ .value = @ptrCast(c.id, @alignCast(@alignOf(c.id), id)) };
    }

    /// Returns the class of an object.
    pub fn getClass(self: Object) ?objc.Class {
        return objc.Class{
            .value = c.object_getClass(self.value) orelse return null,
        };
    }

    /// Returns the class name of a given object.
    pub fn getClassName(self: Object) [:0]const u8 {
        return std.mem.sliceTo(c.object_getClassName(self.value), 0);
    }

    /// Set a property. This is a helper around getProperty and is
    /// strictly less performant than doing it manually. Consider doing
    /// this manually if performance is critical.
    pub fn setProperty(self: Object, comptime n: [:0]const u8, v: anytype) void {
        const Class = self.getClass().?;
        const prop = Class.getProperty(n).?;
        const setter = if (prop.copyAttributeValue("S")) |val| setter: {
            defer objc.free(val);
            break :setter objc.sel(val);
        } else objc.sel(
            "set" ++
                [1]u8{std.ascii.toUpper(n[0])} ++
                n[1..n.len] ++
                ":",
        );

        self.msgSend(void, setter, .{v});
    }

    /// Get a property. This is a helper around Class.getProperty and is
    /// strictly less performant than doing it manually. Consider doing
    /// this manually if performance is critical.
    pub fn getProperty(self: Object, comptime T: type, comptime n: [:0]const u8) T {
        const Class = self.getClass().?;
        const prop = Class.getProperty(n).?;
        const getter = if (prop.copyAttributeValue("G")) |val| getter: {
            defer objc.free(val);
            break :getter objc.sel(val);
        } else objc.sel(n);

        return self.msgSend(T, getter, .{});
    }
};

test {
    const testing = std.testing;
    const NSObject = objc.Class.getClass("NSObject").?;

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    try testing.expectEqualStrings("NSObject", obj.getClassName());
    obj.msgSend(void, objc.sel("dealloc"), .{});
}
