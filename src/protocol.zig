const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolParam = cpkg.boolParam;
const boolResult = cpkg.boolResult;
const objc = @import("main.zig");

pub const Protocol = extern struct {
    value: *c.Protocol,

    pub fn conformsToProtocol(self: Protocol, other: Protocol) bool {
        return boolResult(c.protocol_conformsToProtocol(self.value, other.value));
    }

    pub fn isEqual(self: Protocol, other: Protocol) bool {
        return boolResult(c.protocol_isEqual(self.value, other.value));
    }

    pub fn getName(self: Protocol) [:0]const u8 {
        return std.mem.sliceTo(c.protocol_getName(self.value), 0);
    }

    pub fn getProperty(
        self: Protocol,
        name: [:0]const u8,
        is_required: bool,
        is_instance: bool,
    ) ?objc.Property {
        return .{ .value = c.protocol_getProperty(
            self.value,
            name,
            boolParam(is_required),
            boolParam(is_instance),
        ) orelse return null };
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf([*c]c.Protocol));
        std.debug.assert(@alignOf(@This()) == @alignOf([*c]c.Protocol));
    }
};

pub fn getProtocol(name: [:0]const u8) ?Protocol {
    return .{ .value = c.objc_getProtocol(name) orelse return null };
}
