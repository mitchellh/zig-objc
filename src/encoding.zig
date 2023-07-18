const std = @import("std");
const c = @import("c.zig");
const objc = @import("main.zig");

/// Encoding union which parses type information and turns it into Obj-C runtime Type Encodings.
/// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
/// Used for adding Class ivars and methods, among other things, and mimics the @encode compiler directive in Objective-C
/// It is meant to be used in writer functions, though you can create your own encoding with Union Initilization. Though it's not recommended.
pub const Encoding = union(enum) {
    char,
    short,
    int,
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
    union_e: struct { union_type: type, show_type_spec: bool },
    bitfield: u32,
    pointer: struct { ptr_type: type, size: std.builtin.Type.Pointer.Size },
    function: std.builtin.Type.Fn,
    unknown,

    pub fn newFromType(comptime T: type) Encoding {
        return switch (T) {
            i8, c_char => .char,
            c_short => .short,
            c_int => .int,
            c_long => .long,
            c_longlong => .longlong,
            u8 => .uchar,
            c_ushort => .ushort,
            c_uint => .uint,
            c_ulong => .ulong,
            c_ulonglong => .ulonglong,
            f32 => .float,
            f64 => .double,
            bool => .bool,
            void => .void,
            [*c]u8, [*c]const u8 => .char_string,
            c.SEL, objc.Sel => .selector,
            c.Class, objc.Class => .class,
            c.id => .object,
            else => switch (@typeInfo(T)) {
                .Array => |arr| Encoding{ .array = .{ .len = arr.len, .arr_type = arr.child } },
                .Struct => Encoding{ .structure = .{ .struct_type = T, .show_type_spec = true } },
                .Union => Encoding{ .union_e = .{
                    .union_type = T,
                    .show_type_spec = true,
                } },
                .Pointer => |ptr| Encoding{ .pointer = .{ .ptr_type = T, .size = ptr.size } },
                .Fn => |fn_info| Encoding{ .function = fn_info },
                else => @compileError("Type is not supported"),
            },
        };
    }

    pub fn format(
        comptime self: Encoding,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
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
                const encode_type = Encoding.newFromType(a.arr_type);
                try encode_type.format(fmt, options, writer);
                try writer.writeAll("]");
            },
            .structure => |s| {
                const struct_info = @typeInfo(s.struct_type);
                if (struct_info.Struct.layout != .Extern)
                    @compileError("Structs must be 'extern' for compatability with the C ABI");

                // Strips the fully qualified type name to leave just the type name. Used in naming the Struct in an encoding
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(s.struct_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("{{{s}", .{type_name});

                // if the encoding should show the internal type specification of the struct (determined by levels of pointer indirection)
                if (s.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (struct_info.Struct.fields) |field| {
                        const field_encode = Encoding.newFromType(field.type);
                        try field_encode.format(fmt, options, writer);
                    }
                }

                try writer.writeAll("}");
            },
            .union_e => |u| {
                const union_info = @typeInfo(u.union_type);
                if (union_info.Union.layout != .Extern)
                    @compileError("Unions must be 'extern' for compatability with the C ABI");

                // Strips the fully qualified type name to leave just the type name. Used in naming the Union in an encoding
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(u.union_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("({s}", .{type_name});

                // if the encoding should show the internal type specification of the Union (determined by levels of pointer indirection)
                if (u.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (union_info.Union.fields) |field| {
                        const field_encode = Encoding.newFromType(field.type);
                        try field_encode.format(fmt, options, writer);
                    }
                }

                try writer.writeAll(")");
            },
            .bitfield => |b| try writer.print("b{}", .{b}), // not sure if needed from Zig -> Obj-C
            .pointer => |p| {
                switch (p.size) {
                    .One => {
                        // get the pointer info (count of levels of direction and the underlying type)
                        const pointer_info = indirectionCountAndType(p.ptr_type);
                        // writes a '^' character for each level of pointer indirection
                        for (0..pointer_info.indirection_levels) |_| {
                            try writer.writeAll("^");
                        }

                        // create a new Encoding union from the pointers child type, giving an encoding of the underlying pointer type
                        comptime var encoding: Encoding = Encoding.newFromType(pointer_info.child);

                        // if the indirection levels are greater than 1, for certain types that means getting rid of it's
                        // internal type specification
                        // Apple docs for this: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100
                        if (pointer_info.indirection_levels > 1) {
                            switch (encoding) {
                                .structure => |*s| s.*.show_type_spec = false,
                                .union_e => |*u| u.*.show_type_spec = false,
                                else => {},
                            }
                        }

                        // call this format function again, this time with the child type encoding
                        try encoding.format(fmt, options, writer);
                    },
                    else => @compileError("Pointer size not supported for encoding"),
                }
            },
            .function => |fn_info| {
                if (fn_info.calling_convention != .C)
                    @compileError("Calling convention for function must be 'C' for compatability with the C ABI");

                // Return type is first in a method encoding
                const ret_type_enc = Encoding.newFromType(fn_info.return_type.?);
                try ret_type_enc.format(fmt, options, writer);

                // If more than 2 params, make sure the object and selector are first and second, encode them, and encode the rest
                switch (fn_info.params.len) {
                    0, 1 => {
                        @compileError("There must be a minimum of two params. First for c.id and second for c.SEL");
                    },
                    else => {
                        if (fn_info.params[0].type.? != c.id)
                            @compileError("First argument must be of type c.id");

                        if (fn_info.params[1].type.? != c.SEL)
                            @compileError("Second argument must be of type c.SEL");

                        inline for (fn_info.params) |param| {
                            const param_enc = Encoding.newFromType(param.type.?);
                            try param_enc.format(fmt, options, writer);
                        }
                    },
                }
            },
            .unknown => {},
        }
    }
};

/// This comptime function gets the levels of indirection from a type. If the type is a pointer type it
/// returns the underlying type from the pointer (the child) by walking the pointer to that child.
/// Returns the type and 0 for count if the type isn't a pointer
fn indirectionCountAndType(comptime T: type) struct { child: type, indirection_levels: comptime_int } {
    var WalkType = T;
    var count: usize = 0;
    while (@typeInfo(WalkType) == .Pointer) : (count += 1) {
        WalkType = @typeInfo(WalkType).Pointer.child;
    }
    return .{ .child = WalkType, .indirection_levels = count };
}

test {
    _ = EncodingTests;
}

const EncodingTests = struct {
    const testing = std.testing;

    var buf: [200]u8 = undefined;

    fn encodingMatchesType(comptime T: type, expected_encoding: []const u8) !void {
        buf = undefined;
        const enc = Encoding.newFromType(T);
        const enc_string = try std.fmt.bufPrint(&buf, "{s}", .{enc});
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

    test "Union to Encoding.union_e encoding" {
        const TestUnion = extern union {
            int: c_int,
            short: c_short,
            long: c_long,
        };
        try encodingMatchesType(TestUnion, "(TestUnion=isl)");
    }

    test "*Union to Encoding.union_e encoding" {
        const TestUnion = extern union {
            int: c_int,
            short: c_short,
            long: c_long,
        };
        try encodingMatchesType(*TestUnion, "^(TestUnion=isl)");
    }

    test "**Union to Encoding.union_e encoding" {
        const TestUnion = extern union {
            int: c_int,
            short: c_short,
            long: c_long,
        };
        try encodingMatchesType(**TestUnion, "^^(TestUnion)");
    }

    test "Fn to Encoding.function encoding" {
        const test_fn = struct {
            fn add(_: c.id, _: c.SEL, _: i8) callconv(.C) void {}
        };

        try encodingMatchesType(@TypeOf(test_fn.add), "v@:c");
    }
};
