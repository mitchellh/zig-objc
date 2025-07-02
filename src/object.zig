const std = @import("std");
const c = @import("c.zig").c;
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;
const Iterator = @import("iterator.zig").Iterator;

/// Object is an instance of a class.
pub const Object = struct {
    value: c.id,

    // Implement msgSend
    const msg_send = MsgSend(Object);
    pub const msgSend = msg_send.msgSend;
    pub const msgSendSuper = msg_send.msgSendSuper;

    /// Convert a raw "id" into an Object. id must fit the size of the
    /// normal C "id" type (i.e. a `usize`).
    pub fn fromId(id: anytype) Object {
        if (@sizeOf(@TypeOf(id)) != @sizeOf(c.id)) {
            @compileError("invalid id type");
        }

        // Some pointers in Objective-C are "tagged pointers", which
        // may be used for small objects and literals (NSNumber, NSString).
        // It's an internal implementation detail that replaces heap
        // allocation with direct encoding within the pointer itself.
        // This may result in UNALIGNED POINTERS!
        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
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
    pub fn setProperty(self: Object, comptime n: [*:0]const u8, v: anytype) void {
        const Class = self.getClass().?;
        const setter = setter: {
            // See getProperty for why we do this.
            if (Class.getProperty(n)) |prop| {
                if (prop.copyAttributeValue("S")) |val| {
                    defer objc.free(val);
                    break :setter objc.sel(val);
                }
            }

            break :setter objc.sel(
                "set" ++
                    [1]u8{std.ascii.toUpper(n[0])} ++
                    n[1..n.len] ++
                    ":",
            );
        };

        self.msgSend(void, setter, .{v});
    }

    /// Get a property. This is a helper around Class.getProperty and is
    /// strictly less performant than doing it manually. Consider doing
    /// this manually if performance is critical.
    pub fn getProperty(self: Object, comptime T: type, comptime n: [*:0]const u8) T {
        const Class = self.getClass().?;
        const getter = getter: {
            // Sometimes a property is not a property because it has been
            // overloaded or something. I've found numerous occasions the
            // Apple docs are just wrong, so we try to read it as a property
            // but if we can't then we just call it as-is.
            if (Class.getProperty(n)) |prop| {
                if (prop.copyAttributeValue("G")) |val| {
                    defer objc.free(val);
                    break :getter objc.sel(val);
                }
            }

            break :getter objc.sel(n);
        };

        return self.msgSend(T, getter, .{});
    }

    pub fn copy(self: Object, size: usize) Object {
        return fromId(c.object_copy(self.value, size));
    }

    pub fn dispose(self: Object) void {
        c.object_dispose(self.value);
    }

    pub fn isClass(self: Object) bool {
        return c.object_isClass(self.value) == 1;
    }

    pub fn getInstanceVariable(self: Object, name: [*:0]const u8) Object {
        const ivar = c.object_getInstanceVariable(self.value, name, null);
        return fromId(c.object_getIvar(self.value, ivar));
    }

    pub fn setInstanceVariable(self: Object, name: [*:0]const u8, val: Object) void {
        const ivar = c.object_getInstanceVariable(self.value, name, null);
        c.object_setIvar(self.value, ivar, val.value);
    }

    pub fn retain(self: Object) Object {
        return fromId(objc_retain(self.value));
    }

    pub fn release(self: Object) void {
        objc_release(self.value);
    }

    /// Return an iterator for this object. The object must implement the
    /// `NSFastEnumeration` protocol.
    pub fn iterate(self: Object) Iterator {
        return Iterator.init(self);
    }
};

extern "c" fn objc_retain(objc.c.id) objc.c.id;
extern "c" fn objc_release(objc.c.id) void;

fn retainCount(obj: Object) c_ulong {
    return obj.msgSend(c_ulong, objc.Sel.registerName("retainCount"), .{});
}

test {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    try testing.expectEqualStrings("NSObject", obj.getClassName());
    obj.msgSend(void, objc.sel("dealloc"), .{});
}

test "retain object" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    _ = obj.msgSend(objc.Object, objc.Sel.registerName("init"), .{});
    try testing.expectEqual(@as(c_ulong, 1), retainCount(obj));

    _ = obj.retain();
    try testing.expectEqual(@as(c_ulong, 2), retainCount(obj));

    obj.release();
    try testing.expectEqual(@as(c_ulong, 1), retainCount(obj));

    obj.msgSend(void, objc.sel("dealloc"), .{});
}

test "tagged pointer" {
    const testing = std.testing;

    // We can't force Objective-C to provide us with an unaligned tagged
    // pointer, so we try several times using different classes. We use
    // different classes instead of values, since pointers from the same
    // class will have the same alignment during a single execution (aarch64).
    const obj = blk: {
        var Class = objc.getClass("NSNumber").?;
        var sel = objc.Sel.registerName("numberWithChar:");
        var obj = Class.msgSend(objc.Object, sel, .{@as(u8, @intCast(5))});

        // We're only interested in an unaligned pointer.
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        Class = objc.getClass("NSString").?;
        sel = objc.Sel.registerName("stringWithUTF8String:");
        obj = Class.msgSend(objc.Object, sel, .{"foo"});
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        Class = objc.getClass("NSDate").?;
        sel = objc.Sel.registerName("date");
        obj = Class.msgSend(objc.Object, sel, .{});
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        const colors = [_][:0]const u8{
            "clearColor",    "blackColor",  "blueColor",  "brownColor",     "cyanColor",
            "darkGrayColor", "grayColor",   "greenColor", "lightGrayColor", "magentaColor",
            "orangeColor",   "purpleColor", "redColor",   "whiteColor",     "yellowColor",
        };

        Class = objc.getClass("NSColor").?;
        for (colors) |color| {
            sel = objc.Sel.registerName(color);
            obj = Class.msgSend(objc.Object, sel, .{});
            if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;
        }

        // In the unlikely event that we don't find an unaligned tagged pointer.
        std.log.warn("skipped 'tagged pointer' test because we couldn't find an unaligned tagged pointer", .{});
        return error.SkipZigTest;
    };

    // A tagged object is not allocated on the heap and cannot be retained.
    try testing.expect(retainCount(obj) != 1);

    // `Object.fromId` must work even when the pointer is unaligned.
    const obj_ptr = @intFromPtr(obj.value);
    try testing.expect(!std.mem.isAligned(obj_ptr, @alignOf(usize)));
    try testing.expect(std.meta.eql(obj, Object.fromId(obj.value)));
}
