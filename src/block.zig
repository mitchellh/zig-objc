const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const objc = @import("main.zig");

// We have to use the raw C allocator for all heap allocation in here
// because the objc runtime expects `malloc` to be used. If you don't use
// malloc you'll get segfaults because the objc runtime will try to free
// the memory with `free`.
const alloc = std.heap.raw_c_allocator;

/// Creates a new block type with captured (closed over) values.
///
/// The CapturesArg is the a struct of captured values that will become
/// available to the block. The Args is a tuple of types that are additional
/// invocation-time arguments to the function. The Return param is the return
/// type of the function.
///
/// Within the CapturesArg, only `objc.c.id` values will be automatically
/// memory managed (retained and released) when the block is copied.
/// If you are passing through NSObjects, you should use the `objc.c.id`
/// type and recreate a richer Zig type on the other side.
///
/// The function that must be implemented is available as the `Fn` field.
/// The first argument to the function is always a pointer to the `Context`
/// type (see field in the struct). This has the captured values.
///
/// The captures struct is always available as the `Captures` field which
/// makes it easy to use an inline type definition for the argument and
/// reference the type in a named fashion later.
///
/// The returned block type can be initialized and invoked multiple times
/// for different captures and arguments.
///
/// See the tests for an example.
pub fn Block(
    comptime CapturesArg: type,
    comptime Args: anytype,
    comptime Return: type,
) type {
    return struct {
        const Self = @This();
        const captures_info = @typeInfo(Captures).@"struct";
        const InvokeFn = FnType(anyopaque);
        const descriptor: Descriptor = .{
            .reserved = 0,
            .size = @sizeOf(Context),
            .copy_helper = &descCopyHelper,
            .dispose_helper = &descDisposeHelper,
            .signature = &objc.comptimeEncode(InvokeFn),
        };

        /// This is the function type that is called back.
        pub const Fn = FnType(Context);

        /// The captures type, so it can be easily referenced again.
        pub const Captures = CapturesArg;

        /// This is the block context sent as the first paramter to the function.
        pub const Context = BlockContext(Captures, InvokeFn);

        /// Create a new block context. The block context is what is passed
        /// (by reference) to functions that request a block.
        ///
        /// Note that if the captures contain reference types (like
        /// NSObject), they will NOT be retained/released UNTIL the block
        /// is copied. A block copy happens automatically when the block
        /// is copied to a function that expects a block in ObjC.
        ///
        /// If you want to manualy copy a block, you can use the `copy`
        /// function but you must pair it with a `dispose` function. This
        /// should only be done for blocks that are not passed to external
        /// functions where the runtime will automatically copy them (C,
        /// C++, ObjC, etc.).
        pub fn init(captures: Captures, func: *const Fn) Context {
            // The block starts as a stack-allocated block. We let the
            // runtime copy it to the heap. It doesn't seem to be advisable
            // to allocate it on the heap directly since the way refcounting
            // is done and so on is all private API.
            var ctx: Context = undefined;
            ctx.isa = NSConcreteStackBlock;
            ctx.flags = .{
                .copy_dispose = true,
                .stret = @typeInfo(Return) == .@"struct",
                .signature = true,
            };
            ctx.invoke = @ptrCast(func);
            ctx.descriptor = &descriptor;
            inline for (captures_info.fields) |field| {
                @field(ctx, field.name) = @field(captures, field.name);
            }

            return ctx;
        }

        /// Invoke the block with the given arguments. The arguments are
        /// the arguments to pass to the function beyond the captured scope.
        pub fn invoke(ctx: *const Context, args: anytype) Return {
            return @call(
                .auto,
                ctx.invoke,
                .{ctx} ++ args,
            );
        }

        /// Copies the given context by either literally copying it
        /// to the heap or increasing the reference count. This must be
        /// paired with a `release` call to release the block.
        pub fn copy(ctx: *const Context) Allocator.Error!*Context {
            const copied = _Block_copy(@ptrCast(@alignCast(ctx))) orelse
                return error.OutOfMemory;
            return @ptrCast(@alignCast(copied));
        }

        /// Release a copied block context. This must only be called on
        /// contexts returned by the `copy` function. If you pass a block
        /// context that was not copied, this will crash.
        pub fn release(ctx: *const Context) void {
            assert(@intFromPtr(ctx.isa) == @intFromPtr(NSConcreteMallocBlock));
            _Block_release(@ptrCast(@alignCast(ctx)));
        }

        fn descCopyHelper(src: *anyopaque, dst: *anyopaque) callconv(.c) void {
            const real_src: *Context = @ptrCast(@alignCast(src));
            const real_dst: *Context = @ptrCast(@alignCast(dst));
            inline for (captures_info.fields) |field| {
                if (field.type == objc.c.id) {
                    _Block_object_assign(
                        @ptrCast(&@field(real_dst, field.name)),
                        @field(real_src, field.name),
                        .object,
                    );
                }
            }
        }

        fn descDisposeHelper(src: *anyopaque) callconv(.c) void {
            const real_src: *Context = @ptrCast(@alignCast(src));
            inline for (captures_info.fields) |field| {
                if (field.type == objc.c.id) {
                    _Block_object_dispose(
                        @field(real_src, field.name),
                        .object,
                    );
                }
            }
        }

        /// Creates a function type for the invocation function, but alters
        /// the first arg. The first arg is a pointer so from an ABI perspective
        /// this is always the same and can be safely casted.
        fn FnType(comptime ContextArg: type) type {
            var params: [Args.len + 1]std.builtin.Type.Fn.Param = undefined;
            params[0] = .{ .is_generic = false, .is_noalias = false, .type = *const ContextArg };
            for (Args, 1..) |Arg, i| {
                params[i] = .{ .is_generic = false, .is_noalias = false, .type = Arg };
            }

            return @Type(.{
                .@"fn" = .{
                    .calling_convention = .c,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = Return,
                    .params = &params,
                },
            });
        }
    };
}

/// This is the type of a block structure that is passed as the first
/// argument to any block invocation. See Block.
fn BlockContext(comptime Captures: type, comptime InvokeFn: type) type {
    const captures_info = @typeInfo(Captures).@"struct";
    var fields: [captures_info.fields.len + 5]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "isa",
        .type = ?*anyopaque,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(*anyopaque),
    };
    fields[1] = .{
        .name = "flags",
        .type = BlockFlags,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(c_int),
    };
    fields[2] = .{
        .name = "reserved",
        .type = c_int,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(c_int),
    };
    fields[3] = .{
        .name = "invoke",
        .type = *const InvokeFn,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @typeInfo(*const InvokeFn).pointer.alignment,
    };
    fields[4] = .{
        .name = "descriptor",
        .type = *const Descriptor,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(*Descriptor),
    };

    for (captures_info.fields, 5..) |capture, i| {
        switch (capture.type) {
            comptime_int => @compileError("capture should not be a comptime_int, try using @as"),
            comptime_float => @compileError("capture should not be a comptime_float, try using @as"),
            else => {},
        }

        fields[i] = .{
            .name = capture.name,
            .type = capture.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = capture.alignment,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .@"extern",
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// Pointer to opaque instead of anyopaque: https://github.com/ziglang/zig/issues/18461
const NSConcreteStackBlock = @extern(*opaque {}, .{ .name = "_NSConcreteStackBlock" });
const NSConcreteMallocBlock = @extern(*opaque {}, .{ .name = "_NSConcreteMallocBlock" });

// https://github.com/llvm/llvm-project/blob/734d31a464e204db699c1cf9433494926deb2aa2/compiler-rt/lib/BlocksRuntime/Block_private.h#L101-L108
const BlockFieldFlags = enum(c_int) {
    object = 3, // BLOCK_FIELD_IS_OBJECT
    block = 7, // BLOCK_FIELD_IS_BLOCK
    byref = 8, // BLOCK_FIELD_IS_BYREF
    weak = 16, // BLOCK_FIELD_IS_WEAK
    byref_caller = 128, // BLOCK_BYREF_CALLER
};

extern "C" fn _Block_copy(src: *const anyopaque) callconv(.c) ?*anyopaque;
extern "C" fn _Block_release(src: *const anyopaque) callconv(.c) void;
extern "C" fn _Block_object_assign(dst: *anyopaque, src: *const anyopaque, flag: BlockFieldFlags) void;
extern "C" fn _Block_object_dispose(src: *const anyopaque, flag: BlockFieldFlags) void;

const Descriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
    copy_helper: *const fn (dst: *anyopaque, src: *anyopaque) callconv(.c) void,
    dispose_helper: *const fn (src: *anyopaque) callconv(.c) void,
    signature: ?[*:0]const u8,
};

const BlockFlags = packed struct(c_int) {
    _unused: u23 = 0,
    noescape: bool = false,
    _unused_2: u1 = 0,
    copy_dispose: bool = false,
    ctor: bool = false,
    _unused_3: u1 = 0,
    global: bool = false,
    stret: bool = false,
    signature: bool = false,
    _unused_4: u1 = 0,
};

test "Block" {
    const AddBlock = Block(struct {
        x: i32,
        y: i32,
    }, .{}, i32);

    const captures: AddBlock.Captures = .{
        .x = 2,
        .y = 3,
    };

    var block: AddBlock.Context = AddBlock.init(captures, (struct {
        fn addFn(block: *const AddBlock.Context) callconv(.c) i32 {
            return block.x + block.y;
        }
    }).addFn);

    const ret = AddBlock.invoke(&block, .{});
    try std.testing.expectEqual(@as(i32, 5), ret);

    // Try copy and release
    const copied = try AddBlock.copy(&block);
    AddBlock.release(copied);
}

test "Block copy objc id" {
    // Create an object, refcount 1
    const NSObject = objc.getClass("NSObject").?;
    const obj = NSObject.msgSend(
        objc.Object,
        objc.Sel.registerName("alloc"),
        .{},
    );
    _ = obj.msgSend(objc.Object, objc.Sel.registerName("init"), .{});

    const TestBlock = Block(struct {
        id: objc.c.id,
    }, .{}, i32);

    var block = TestBlock.init(.{
        .id = obj.value,
    }, (struct {
        fn addFn(block: *const TestBlock.Context) callconv(.c) i32 {
            _ = block;
            return 0;
        }
    }).addFn);

    // Try copy and release
    const copied = try TestBlock.copy(&block);
    TestBlock.release(copied);
}
