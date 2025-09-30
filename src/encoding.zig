const std = @import("std");
const objc = @import("main.zig");
const c = @import("c.zig").c;
const assert = std.debug.assert;
const testing = std.testing;

/// how much space do we need to encode this type?
fn comptimeN(comptime T: type) usize {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Figure out how much space we need
        var stream: std.io.Writer.Discarding = .init(&.{});
        stream.writer.print("{f}", .{encoding}) catch unreachable;
        return stream.count;
    }
}

/// Encode a type into a comptime string.
pub fn comptimeEncode(comptime T: type) [comptimeN(T):0]u8 {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Build our final signature
        var buf: [comptimeN(T) + 1]u8 = undefined;
        var fbs: std.io.Writer = .fixed(buf[0 .. buf.len - 1]);
        fbs.print("{f}", .{encoding}) catch unreachable;
        buf[buf.len - 1] = 0;

        return buf[0 .. buf.len - 1 :0].*;
    }
}

/// Encoding union which parses type information and turns it into Obj-C
/// runtime Type Encodings.
///
/// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
pub const Encoding = union(enum) {
    char,
    int,
    short,
    long,
    longlong,
    uchar,
    uint,
    ushort,
    ulong,
    ulonglong,
    float,
    double,
    bool,
    void,
    char_string,
    object,
    class,
    selector,
    array: struct { arr_type: type, len: usize },
    structure: struct { struct_type: type, show_type_spec: bool },
    @"union": struct { union_type: type, show_type_spec: bool },
    bitfield: u32,
    pointer: struct { ptr_type: type, size: std.builtin.Type.Pointer.Size },
    function: std.builtin.Type.Fn,
    unknown,

    pub fn init(comptime T: type) Encoding {
        return switch (T) {
            i8, c_char => .char,
            c_short => .short,
            i32, c_int => .int,
            c_long => .long,
            i64, c_longlong => .longlong,
            u8 => .uchar,
            c_ushort => .ushort,
            u32, c_uint => .uint,
            c_ulong => .ulong,
            u64, c_ulonglong => .ulonglong,
            f32 => .float,
            f64 => .double,
            bool => .bool,
            void, anyopaque => .void,
            [*c]u8, [*c]const u8 => .char_string,
            c.SEL, objc.Sel => .selector,
            c.Class, objc.Class => .class,
            c.id, objc.Object => .object,
            else => switch (@typeInfo(T)) {
                .@"opaque" => .void,
                .@"enum" => |m| .init(m.tag_type),
                .array => |arr| .{ .array = .{ .len = arr.len, .arr_type = arr.child } },
                .@"struct" => |m| switch (m.layout) {
                    .@"packed" => .init(m.backing_integer.?),
                    else => .{ .structure = .{ .struct_type = T, .show_type_spec = true } },
                },
                .@"union" => .{ .@"union" = .{
                    .union_type = T,
                    .show_type_spec = true,
                } },
                .optional => |m| switch (@typeInfo(m.child)) {
                    .pointer => |ptr| .{ .pointer = .{ .ptr_type = m.child, .size = ptr.size } },
                    else => @compileError("unsupported non-pointer optional type: " ++ @typeName(T)),
                },
                .pointer => |ptr| .{ .pointer = .{ .ptr_type = T, .size = ptr.size } },
                .@"fn" => |fn_info| .{ .function = fn_info },
                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }

    pub fn format(
        comptime self: Encoding,
        writer: *std.io.Writer,
    ) !void {
        switch (self) {
            .char => try writer.writeAll("c"),
            .int => try writer.writeAll("i"),
            .short => try writer.writeAll("s"),
            .long => try writer.writeAll("l"),
            .longlong => try writer.writeAll("q"),
            .uchar => try writer.writeAll("C"),
            .uint => try writer.writeAll("I"),
            .ushort => try writer.writeAll("S"),
            .ulong => try writer.writeAll("L"),
            .ulonglong => try writer.writeAll("Q"),
            .float => try writer.writeAll("f"),
            .double => try writer.writeAll("d"),
            .bool => try writer.writeAll("B"),
            .void => try writer.writeAll("v"),
            .char_string => try writer.writeAll("*"),
            .object => try writer.writeAll("@"),
            .class => try writer.writeAll("#"),
            .selector => try writer.writeAll(":"),
            .array => |a| {
                try writer.print("[{}", .{a.len});
                const encode_type = init(a.arr_type);
                try encode_type.format(writer);
                try writer.writeAll("]");
            },
            .structure => |s| {
                const struct_info = @typeInfo(s.struct_type);
                assert(struct_info.@"struct".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Struct in an encoding.
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(s.struct_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("{{{s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the struct (determined by levels of pointer indirection)
                if (s.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (struct_info.@"struct".fields) |field| {
                        const field_encode = init(field.type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll("}");
            },
            .@"union" => |u| {
                const union_info = @typeInfo(u.union_type);
                assert(union_info.@"union".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Union in an encoding
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(u.union_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("({s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the Union (determined by levels of pointer indirection)
                if (u.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (union_info.@"union".fields) |field| {
                        const field_encode = init(field.type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll(")");
            },
            .bitfield => |b| try writer.print("b{}", .{b}), // not sure if needed from Zig -> Obj-C
            .pointer => |p| {
                switch (p.size) {
                    .one => {
                        // get the pointer info (count of levels of direction
                        // and the underlying type)
                        const pointer_info = indirectionCountAndType(p.ptr_type);
                        for (0..pointer_info.indirection_levels) |_| {
                            try writer.writeAll("^");
                        }

                        // create a new Encoding union from the pointers child
                        // type, giving an encoding of the underlying pointer type
                        comptime var encoding = init(pointer_info.child);

                        // if the indirection levels are greater than 1, for
                        // certain types that means getting rid of it's
                        // internal type specification
                        //
                        // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100
                        if (pointer_info.indirection_levels > 1) {
                            switch (encoding) {
                                .structure => |*s| s.show_type_spec = false,
                                .@"union" => |*u| u.show_type_spec = false,
                                else => {},
                            }
                        }

                        // call this format function again, this time with the child type encoding
                        try encoding.format(writer);
                    },
                    else => @compileError("Pointer size not supported for encoding"),
                }
            },
            .function => |fn_info| {
                assert(std.meta.eql(fn_info.calling_convention, std.builtin.CallingConvention.c));

                // Return type is first in a method encoding
                const ret_type_enc = init(fn_info.return_type.?);
                try ret_type_enc.format(writer);
                inline for (fn_info.params) |param| {
                    const param_enc = init(param.type.?);
                    try param_enc.format(writer);
                }
            },
            .unknown => {},
        }
    }
};

/// This comptime function gets the levels of indirection from a type. If the type is a pointer type it
/// returns the underlying type from the pointer (the child) by walking the pointer to that child.
/// Returns the type and 0 for count if the type isn't a pointer
fn indirectionCountAndType(comptime T: type) struct {
    child: type,
    indirection_levels: comptime_int,
} {
    var WalkType = T;
    var count: usize = 0;
    while (@typeInfo(WalkType) == .pointer) : (count += 1) {
        WalkType = @typeInfo(WalkType).pointer.child;
    }

    return .{ .child = WalkType, .indirection_levels = count };
}

fn encodingMatchesType(comptime T: type, expected_encoding: []const u8) !void {
    var buf: [200]u8 = undefined;
    const enc = Encoding.init(T);
    const enc_string = try std.fmt.bufPrint(&buf, "{f}", .{enc});
    try testing.expectEqualStrings(expected_encoding, enc_string);
}

test "i8 to Encoding.char encoding" {
    try encodingMatchesType(i8, "c");
}

test "c_char to Encoding.char encoding" {
    try encodingMatchesType(c_char, "c");
}

test "c_short to Encoding.short encoding" {
    try encodingMatchesType(c_short, "s");
}

test "c_int to Encoding.int encoding" {
    try encodingMatchesType(c_int, "i");
}

test "c_long to Encoding.long encoding" {
    try encodingMatchesType(c_long, "l");
}

test "c_longlong to Encoding.longlong encoding" {
    try encodingMatchesType(c_longlong, "q");
}

test "u8 to Encoding.uchar encoding" {
    try encodingMatchesType(u8, "C");
}

test "c_ushort to Encoding.ushort encoding" {
    try encodingMatchesType(c_ushort, "S");
}

test "c_uint to Encoding.uint encoding" {
    try encodingMatchesType(c_uint, "I");
}

test "c_ulong to Encoding.ulong encoding" {
    try encodingMatchesType(c_ulong, "L");
}

test "c_ulonglong to Encoding.ulonglong encoding" {
    try encodingMatchesType(c_ulonglong, "Q");
}

test "f32 to Encoding.float encoding" {
    try encodingMatchesType(f32, "f");
}

test "f64 to Encoding.double encoding" {
    try encodingMatchesType(f64, "d");
}

test "[4]i8 to Encoding.array encoding" {
    try encodingMatchesType([4]i8, "[4c]");
}

test "*u8 to Encoding.pointer encoding" {
    try encodingMatchesType(*u8, "^C");
}

test "**u8 to Encoding.pointer encoding" {
    try encodingMatchesType(**u8, "^^C");
}

test "?*u8 to Encoding.pointer encoding" {
    try encodingMatchesType(?*u8, "^C");
}

test "Enum(c_uint) to Encoding.uint encoding" {
    const TestEnum = enum(c_uint) {};
    try encodingMatchesType(TestEnum, "I");
}

test "TestPackedStruct to Encoding.uint encoding" {
    const TestPackedStruct = packed struct(u32) {
        _: u32,
    };
    try encodingMatchesType(TestPackedStruct, "I");
}

test "*TestStruct to Encoding.pointer encoding" {
    const TestStruct = extern struct {
        float: f32,
        char: u8,
    };
    try encodingMatchesType(*TestStruct, "^{TestStruct=fC}");
}

test "**TestStruct to Encoding.pointer encoding" {
    const TestStruct = extern struct {
        float: f32,
        char: u8,
    };
    try encodingMatchesType(**TestStruct, "^^{TestStruct}");
}

test "*TestStruct with 2 level indirection NestedStruct to Encoding.pointer encoding" {
    const NestedStruct = extern struct {
        char: i8,
    };
    const TestStruct = extern struct {
        float: f32,
        char: u8,
        nested: **NestedStruct,
    };
    try encodingMatchesType(*TestStruct, "^{TestStruct=fC^^{NestedStruct}}");
}

test "*TestOpaque to Encoding.pointer encoding" {
    const TestOpaque = opaque {};
    try encodingMatchesType(*TestOpaque, "^v");
}

test "?*TestOpaque to Encoding.pointer encoding" {
    const TestOpaque = opaque {};
    try encodingMatchesType(?*TestOpaque, "^v");
}

test "Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(TestUnion, "(TestUnion=isl)");
}

test "*Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(*TestUnion, "^(TestUnion=isl)");
}

test "**Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(**TestUnion, "^^(TestUnion)");
}

test "Fn to Encoding.function encoding" {
    const test_fn = struct {
        fn add(_: c.id, _: c.SEL, _: i8) callconv(.c) void {}
    };

    try encodingMatchesType(@TypeOf(test_fn.add), "v@:c");
}
