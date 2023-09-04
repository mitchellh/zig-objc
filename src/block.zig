const std = @import("std");
const objc = @import("main.zig");

const NSConcreteStackBlock = @extern(*anyopaque, .{
    .name = "_NSConcreteStackBlock",
});

extern "C" fn _Block_object_assign(dst: *anyopaque, src: *const anyopaque, flag: c_int) void;
extern "C" fn _Block_object_dispose(src: *const anyopaque, flag: c_int) void;

/// captures is either a struct type or a struct literal
// whose fields will be added to the block
// captures should not be a tuple
// blockFn is either a function type or an actual function
pub fn Block(comptime captures: anytype, comptime blockFn: anytype) type {
    const Captures = @TypeOf(captures);
    const BlockFn = @TypeOf(blockFn);
    const captures_info = @typeInfo(Captures);
    const blockfn_info = @typeInfo(BlockFn);
    const real_captures_info = switch (captures_info) {
        .Type => @typeInfo(captures).Struct,
        .Struct => |s| s,
        else => @compileError("captures should be a struct type or struct literal"),
    };
    const real_blockfn_info = switch (blockfn_info) {
        .Type => @typeInfo(blockFn).Fn,
        .Fn => |f| f,
        .Pointer => |p| @typeInfo(p.child).Fn,
        else => @compileError("blockFn should be a function type or a function"),
    };
    const Return = real_blockfn_info.return_type.?;
    const params = real_blockfn_info.params;
    // an invoke function takes at least one argument: a block.
    std.debug.assert(params.len > 0);
    // an invoke function's first argument, a block, must be *anyopaque.
    std.debug.assert(params[0].type == *anyopaque);
    const fields: []std.builtin.Type.StructField = fields: {
        var acc: [real_captures_info.fields.len + 5]std.builtin.Type.StructField = undefined;
        acc[0] = .{
            .name = "isa",
            .type = ?*anyopaque,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(*anyopaque),
        };
        acc[1] = .{
            .name = "flags",
            .type = c_int,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(c_int),
        };
        acc[2] = .{
            .name = "reserved",
            .type = c_int,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(c_int),
        };
        acc[3] = .{
            .name = "invoke",
            .type = *const @Type(.{
                .Fn = .{
                    .calling_convention = .C,
                    .alignment = @typeInfo(fn () callconv(.C) void).Fn.alignment,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = Return,
                    .params = params,
                },
            }),
            .default_value = null,
            .is_comptime = false,
            .alignment = @typeInfo(*const fn () callconv(.C) void).Pointer.alignment,
        };
        acc[4] = .{
            .name = "descriptor",
            .type = *Descriptor,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(*Descriptor),
        };
        std.debug.assert(!real_captures_info.is_tuple);
        for (real_captures_info.fields, 0..) |capture, i| {
            switch (capture.type) {
                comptime_int => @compileError("capture should not be a comptime_int! try using @as"),
                comptime_float => @compileError("capture should not be a comptime_float! try using @as"),
                else => {},
            }
            acc[5 + i] = .{
                .name = capture.name,
                .type = capture.type,
                .default_value = null,
                .is_comptime = false,
                .alignment = capture.alignment,
            };
        }
        break :fields &acc;
    };
    return @Type(.{
        .Struct = .{
            .layout = .Extern,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// creates a block (on the heap, using malloc) of type T,
// which should be the output of Block,
// assigns the given captures
// (which should be a struct literal with correct names)
// and assigns the given function
// (which should have the correct signature and C calling convention)
// to the block.
// Objective-C will free block pointers itself,
// otherwise you can call free on it yourself.
pub fn initBlock(comptime T: type, captures: anytype, blockFn: anytype) *T {
    const allocator = std.heap.raw_c_allocator;
    var ret = allocator.create(T) catch @panic("OOM!");
    const captures_info = @typeInfo(@TypeOf(captures)).Struct;
    var fn_is_pointer = false;
    const fn_info = switch (@typeInfo(@TypeOf(blockFn))) {
        .Fn => |f| f,
        .Pointer => |p| blk: {
            fn_is_pointer = true;
            break :blk @typeInfo(p.child).Fn;
        },
        else => @compileError("blockFn should be a function!"),
    };
    std.debug.assert(fn_info.calling_convention == .C);
    const Return = fn_info.return_type.?;
    const ret_type = @typeInfo(Return);
    const flags: BlockFlags = .{
        .stret = ret_type == .Struct,
    };
    @field(ret, "isa") = NSConcreteStackBlock;
    @field(ret, "flags") = @as(c_int, @bitCast(flags));
    @field(ret, "reserved") = undefined;
    @field(ret, "invoke") = if (fn_is_pointer) blockFn else &blockFn;
    const inner = struct {
        fn copy_helper(src: *anyopaque, dst: *anyopaque) callconv(.C) void {
            var real_src: *T = @ptrCast(@alignCast(src));
            var real_dst: *T = @ptrCast(@alignCast(dst));
            inline for (captures_info.fields) |field| {
                if (field.type == objc.c.id) {
                    var dst_field = @field(real_dst, field.name);
                    const src_field = @field(real_src, field.name);
                    _Block_object_assign(dst_field, src_field, 3);
                }
            }
        }
        fn dispose_helper(src: *anyopaque) callconv(.C) void {
            const real_src: *T = @ptrCast(@alignCast(src));
            inline for (captures_info.fields) |field| {
                if (field.type == objc.c.id) {
                    _Block_object_dispose(@field(real_src, field.name), 3);
                }
                std.heap.raw_c_allocator.free(std.mem.sliceTo(@field(@field(real_src, "descriptor"), "signature").?, 0));
                std.heap.raw_c_allocator.destroy(@field(real_src, "descriptor"));
            }
        }
    };
    const signature = encodeFn(Return, fn_info.params) catch @panic("OOM!");
    var descriptor = allocator.create(Descriptor) catch @panic("OOM!");
    descriptor.* = .{
        .reserved = 0,
        .size = @sizeOf(T),
        .copy_helper = inner.copy_helper,
        .dispose_helper = inner.dispose_helper,
        .signature = signature.ptr,
    };
    @field(ret, "descriptor") = descriptor;
    inline for (captures_info.fields) |field| {
        @field(ret, field.name) = @field(captures, field.name);
    }
    return ret;
}

/// contents must be freed with 'free'
pub fn encodeFn(
    comptime Return: type,
    comptime Args: []const std.builtin.Type.Fn.Param,
) ![:0]const u8 {
    var allocator = std.heap.raw_c_allocator;
    const String = std.ArrayList(u8);
    var list = try String.initCapacity(allocator, 1024);
    defer list.deinit();
    const str = try encode_inner(Return);
    try list.appendSlice(str);
    allocator.free(str);
    inline for (Args) |arg| {
        const arg_str = try encode_inner(arg.type.?);
        defer allocator.free(arg_str);
        try list.appendSlice(arg_str);
    }
    return allocator.dupeZ(u8, list.items);
}

fn encode_inner(comptime T: type) ![]const u8 {
    var allocator = std.heap.raw_c_allocator;
    const String = std.ArrayList(u8);
    var list = try String.initCapacity(allocator, 128);
    defer list.deinit();
    switch (T) {
        objc.Object, objc.c.id => try list.append('@'),
        objc.Class, objc.c.Class => try list.append('#'),
        objc.Sel, objc.c.SEL => try list.append(':'),
        bool => try list.append('B'),
        u8 => try list.append('C'),
        i8 => try list.append('c'),
        u16 => try list.append('S'),
        i16 => try list.append('s'),
        u32, c_uint => try list.append('I'),
        i32, c_int => try list.append('i'),
        u64, c_ulong, c_ulonglong => try list.append('Q'),
        i64, c_long, c_longlong => try list.append('q'),
        f32 => try list.append('f'),
        f64 => try list.append('d'),
        [:0]const u8, [*c]const u8, [:0]u8, [*c]u8 => try list.append('*'),
        void => try list.append('v'),
        else => {
            const type_info = @typeInfo(T);
            switch (type_info) {
                .Struct => |s| {
                    try list.appendSlice("{?=");
                    for (s.fields) |field| {
                        const str = try encode_inner(field.type);
                        defer allocator.free(str);
                        try list.appendSlice(str);
                    }
                    try list.appendSlice("}");
                },
                .Union => |u| {
                    try list.appendSlice("(?=");
                    for (u.fields) |field| {
                        const str = try encode_inner(field.type);
                        defer allocator.free(str);
                        try list.appendSlice(str);
                    }
                    try list.appendSlice(")");
                },
                .Pointer => |p| {
                    try list.append('^');
                    const str = try encode_inner(p.child);
                    defer allocator.free(str);
                    try list.appendSlice(str);
                },
                .Fn => try list.append('?'),
                .Opaque => try list.append('v'),
                else => @compileError("unsupported type for encode(): " ++ @typeName(T)),
            }
        },
    }
    return allocator.dupe(u8, list.items);
}

/// contents must be freed with 'free'
pub fn encode(comptime T: type) ![:0]const u8 {
    const allocator = std.heap.raw_c_allocator;
    const str = try encode_inner(T);
    defer allocator.free(str);
    return allocator.dupeZ(u8, str);
}

const Descriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
    copy_helper: *const fn (dst: *anyopaque, src: *anyopaque) callconv(.C) void,
    dispose_helper: *const fn (src: *anyopaque) callconv(.C) void,
    signature: ?[*:0]const u8,
};

const BlockFlags = packed struct {
    _unused: u22 = 0,
    noescape: bool = false,
    _unused_2: bool = false,
    copy_dispose: bool = true,
    ctor: bool = false,
    _unused_3: bool = false,
    global: bool = false,
    stret: bool,
    signature: bool = true,
    _unused_4: u2 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(c_int));
        std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(c_int));
    }
};

pub fn invokeBlock(comptime T: type, comptime Return: type, block: *T, args: anytype) Return {
    var invoke = @field(block, "invoke");
    const ret: Return = @call(.auto, invoke, .{block} ++ args);
    return ret;
}

test "Block and invokeBlock" {
    const Captures = struct {
        x: i32,
        y: i32,
    };
    const AddBlock = Block(Captures, fn (block: *anyopaque) i32);
    const captures = .{
        .x = 2,
        .y = 3,
    };
    const inner = struct {
        fn addFn(block: *anyopaque) callconv(.C) i32 {
            const realBlock: *AddBlock = @ptrCast(@alignCast(block));
            return realBlock.x + realBlock.y;
        }
    };
    var block = initBlock(AddBlock, captures, inner.addFn);
    defer std.heap.raw_c_allocator.destroy(block);
    const ret = invokeBlock(AddBlock, i32, block, .{});
    try std.testing.expectEqual(@as(i32, 5), ret);
}
