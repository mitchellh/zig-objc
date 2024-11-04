const std = @import("std");

const autorelease = @import("autorelease.zig");
const block = @import("block.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const iterator = @import("iterator.zig");
const object = @import("object.zig");
const property = @import("property.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

pub const c = @import("c.zig").c;
pub const AutoreleasePool = autorelease.AutoreleasePool;
pub const Block = block.Block;
pub const Class = class.Class;
pub const getClass = class.getClass;
pub const getMetaClass = class.getMetaClass;
pub const allocateClassPair = class.allocateClassPair;
pub const registerClassPair = class.registerClassPair;
pub const disposeClassPair = class.disposeClassPair;
pub const Encoding = encoding.Encoding;
pub const comptimeEncode = encoding.comptimeEncode;
pub const Iterator = iterator.Iterator;
pub const Object = object.Object;
pub const Property = property.Property;
pub const Protocol = protocol.Protocol;
pub const getProtocol = protocol.getProtocol;
pub const sel = selpkg.sel;
pub const Sel = selpkg.Sel;

/// This just calls the C allocator free. Some things need to be freed
/// and this is how they can be freed for objc.
pub inline fn free(ptr: anytype) void {
    std.heap.c_allocator.free(ptr);
}

test {
    std.testing.refAllDecls(@This());
}
