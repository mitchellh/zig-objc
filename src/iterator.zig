const std = @import("std");
const objc = @import("main.zig");

// From <Foundation/NSEnumerator.h>.
const NSFastEnumerationState = extern struct {
    state: c_ulong = 0,
    itemsPtr: ?[*]objc.c.id = null,
    mutationsPtr: ?*c_ulong = null,
    extra: [5]c_ulong = [_]c_ulong{0} ** 5,
};

/// An iterator that uses the fast enumeration protocol[1] to iterate over
/// objects in an Objective-C collection. This can be used with any object
/// that conforms to the `NSFastEnumeration` protocol.
///
/// [1]: Nhttps://developer.apple.com/documentation/foundation/nsfastenumeration
pub const Iterator = struct {
    object: objc.Object,
    sel: objc.Sel,
    state: NSFastEnumerationState = .{},
    initial_mutations_value: ?c_ulong = null,
    // Clang compiles `for…in` loops with a size 16 buffer.
    buffer: [16]objc.c.id = [_]objc.c.id{null} ** 16,
    slice: []const objc.c.id = &.{},

    pub fn init(object: objc.Object) Iterator {
        return .{
            .object = object,
            .sel = objc.sel("countByEnumeratingWithState:objects:count:"),
        };
    }

    pub fn next(self: *Iterator) ?objc.Object {
        if (self.slice.len == 0) {
            // Ask for some more objects.
            const count = self.object.msgSend(c_ulong, self.sel, .{
                &self.state,
                &self.buffer,
                self.buffer.len,
            });
            if (self.initial_mutations_value) |value| {
                // Call the mutation handler if the mutations value has
                // changed since the start of iteration.
                if (value != self.state.mutationsPtr.?.*) {
                    objc.c.objc_enumerationMutation(self.object.value);
                }
            } else {
                self.initial_mutations_value = self.state.mutationsPtr.?.*;
            }
            self.slice = self.state.itemsPtr.?[0..count];
        }

        if (self.slice.len == 0) return null;

        const first = self.slice[0];
        self.slice = self.slice[1..];
        return objc.Object.fromId(first);
    }
};

test "NSArray iteration" {
    const testing = std.testing;
    const NSArray = objc.getClass("NSMutableArray").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const array = NSArray.msgSend(
        objc.Object,
        "arrayWithCapacity:",
        .{@as(c_ulong, 10)},
    );
    defer array.release();
    for (0..@as(c_int, 10)) |i| {
        const i_number = NSNumber.msgSend(objc.Object, "numberWithInt:", .{i});
        defer i_number.release();
        array.msgSend(void, "addObject:", .{i_number});
    }
    var result: c_int = 0;
    var iter = array.iterate();
    while (iter.next()) |elem| {
        result = (result * 10) + elem.getProperty(c_int, "intValue");
    }
    try testing.expectEqual(123456789, result);
}

test "NSDictionary iteration" {
    const testing = std.testing;
    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const dict = NSMutableDictionary.msgSend(
        objc.Object,
        "dictionaryWithCapacity:",
        .{@as(c_ulong, 100)},
    );
    defer dict.release();
    for (0..@as(c_int, 100)) |i| {
        const i_number = NSNumber.msgSend(objc.Object, "numberWithInt:", .{i});
        defer i_number.release();
        dict.msgSend(void, "setValue:forKey:", .{
            i_number,
            i_number.getProperty(objc.Object, "stringValue"),
        });
    }
    var result: c_int = 0;
    var iter = dict.iterate();
    while (iter.next()) |key| {
        const value = dict.msgSend(objc.Object, "valueForKey:", .{key});
        result += value.getProperty(c_int, "intValue");
    }
    try testing.expectEqual(4950, result);
}
