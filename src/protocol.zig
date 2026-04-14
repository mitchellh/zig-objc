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
        return std.mem.span(c.protocol_getName(self.value));
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

test Protocol {
    const testing = std.testing;
    const fs_proto = getProtocol("NSFileManagerDelegate") orelse return error.ProtocolNotFound;
    try testing.expectEqualStrings("NSFileManagerDelegate", fs_proto.getName());

    const obj_proto = getProtocol("NSObject") orelse return error.ProtocolNotFound;
    try testing.expect(fs_proto.conformsToProtocol(obj_proto));

    const url_proto = getProtocol("NSURLSessionDelegate") orelse return error.ProtocolNotFound;
    try testing.expect(!fs_proto.conformsToProtocol(url_proto));

    const hash_prop = obj_proto.getProperty("hash", true, true) orelse return error.ProtocolPropertyNotFound;
    try testing.expectEqualStrings("hash", hash_prop.getName());
}
