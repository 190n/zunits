const std = @import("std");
const c = @import("quickjs.h");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const MallocFunctions = struct {
    const alignment = @alignOf(std.c.max_align_t);
    comptime {
        assert(alignment >= @sizeOf(usize));
    }
    const padding = alignment;

    const log = std.log.scoped(.js_alloc);

    /// Given an allocation used by C code (offset from the start of the Zig allocation), returns a
    /// pointer to the place where the size for that allocation should be stored
    fn sizeLocation(any_ptr: anytype) if (@typeInfo(@TypeOf(any_ptr)).pointer.is_const)
        *const usize
    else
        *usize {
        const byte_ptr: if (@typeInfo(@TypeOf(any_ptr)).pointer.is_const)
            [*]const u8
        else
            [*]u8 = @ptrCast(any_ptr);
        return @alignCast(@ptrCast(byte_ptr - padding));
    }

    fn js_calloc(ctx: ?*anyopaque, count: usize, size: usize) callconv(.C) ?*anyopaque {
        log.debug("calloc(count = {}, size = {})", .{ count, size });
        const allocator: *Allocator = @alignCast(@ptrCast(ctx.?));
        const bytes = std.math.mul(usize, count, size) catch return null;
        const raw_slice = allocator.alignedAlloc(u8, alignment, bytes + padding) catch return null;
        const c_slice = raw_slice[padding..];
        @memset(c_slice, 0);
        sizeLocation(c_slice.ptr).* = bytes;
        return @ptrCast(c_slice.ptr);
    }

    fn js_malloc(ctx: ?*anyopaque, bytes: usize) callconv(.C) ?*anyopaque {
        log.debug("malloc({})", .{bytes});
        const allocator: *Allocator = @alignCast(@ptrCast(ctx.?));
        const raw_slice = allocator.alignedAlloc(u8, alignment, bytes + padding) catch return null;
        const c_slice = raw_slice[padding..];
        sizeLocation(c_slice.ptr).* = bytes;
        return @ptrCast(c_slice.ptr);
    }

    fn js_free(ctx: ?*anyopaque, maybe_ptr: ?*anyopaque) callconv(.C) void {
        log.debug("free(0x{x})", .{@intFromPtr(maybe_ptr)});
        const ptr = maybe_ptr orelse return;
        const allocator: *Allocator = @alignCast(@ptrCast(ctx.?));
        const size_ptr = sizeLocation(ptr);
        const allocated_ptr: [*]align(alignment) u8 = @alignCast(@ptrCast(size_ptr));
        const allocated_slice = allocated_ptr[0 .. size_ptr.* + padding];
        allocator.free(allocated_slice);
    }

    fn js_realloc(ctx: ?*anyopaque, maybe_ptr: ?*anyopaque, new_size: usize) callconv(.C) ?*anyopaque {
        log.debug("realloc(0x{x} -> {})", .{ @intFromPtr(maybe_ptr), new_size });
        const ptr = maybe_ptr orelse return js_malloc(ctx, new_size);
        if (new_size == 0) {
            js_free(ctx, maybe_ptr);
            return null;
        }

        const allocator: *Allocator = @alignCast(@ptrCast(ctx.?));
        const size_ptr = sizeLocation(ptr);
        log.debug("-> old size = {}", .{size_ptr.*});
        const allocated_ptr: [*]align(alignment) u8 = @alignCast(@ptrCast(size_ptr));
        const allocated_slice = allocated_ptr[0 .. size_ptr.* + padding];

        const new_raw_slice = allocator.realloc(allocated_slice, new_size + padding) catch return null;
        const new_c_slice = new_raw_slice[padding..];
        sizeLocation(new_c_slice.ptr).* = new_size;
        return new_c_slice.ptr;
    }

    fn js_malloc_usable_size(maybe_ptr: ?*const anyopaque) callconv(.C) usize {
        return sizeLocation(maybe_ptr orelse return 0).*;
    }
};

const malloc_functions: c.JSMallocFunctions = .{
    .js_calloc = MallocFunctions.js_calloc,
    .js_malloc = MallocFunctions.js_malloc,
    .js_free = MallocFunctions.js_free,
    .js_realloc = MallocFunctions.js_realloc,
    .js_malloc_usable_size = MallocFunctions.js_malloc_usable_size,
};

/// Wraps a QuickJS runtime using a Zig type to store data alongside the runtime
pub fn Runtime(comptime EmbedderData: type) type {
    return opaque {
        const Self = @This();
        const log = std.log.scoped(.runtime);

        /// Struct that wraps the embedder data and also contains the allocator, so that we can
        /// access the allocator later
        const Opaque = struct {
            data: EmbedderData,
            allocator: Allocator,
        };

        fn getOpaque(self: *Self) *Opaque {
            return @alignCast(@ptrCast(c.JS_GetRuntimeOpaque(self.asQuickJS()).?));
        }

        /// Get self as a pointer to the QuickJS struct
        fn asQuickJS(self: *Self) *c.JSRuntime {
            return @ptrCast(self);
        }

        pub fn create(the_allocator: Allocator, embedder_data: EmbedderData) Allocator.Error!*Self {
            log.info("create runtime, NaN boxing = {}", .{@hasDecl(c, "JS_NAN_BOXING")});

            // use the allocator to put the context on the heap, since we need a stable pointer
            const opaque_ptr = try the_allocator.create(Opaque);
            opaque_ptr.* = .{
                .data = embedder_data,
                .allocator = the_allocator,
            };
            // malloc functions expect a *Allocator for their context
            const runtime = c.JS_NewRuntime2(&malloc_functions, @ptrCast(&opaque_ptr.allocator)) orelse return error.OutOfMemory;
            c.JS_SetRuntimeOpaque(runtime, @ptrCast(opaque_ptr));
            return @ptrCast(runtime);
        }

        /// Access the allocator passed into create()
        pub fn allocator(self: *Self) Allocator {
            return self.getOpaque().allocator;
        }

        /// Access the embedder data passed into create()
        pub fn data(self: *Self) EmbedderData {
            return self.getOpaque().data;
        }

        /// Frees memory used by the runtime, and returns the embedder data that had been associated with it
        pub fn deinit(self: *Self) EmbedderData {
            const opaque_ptr = self.getOpaque();
            // extract these to separate variables so we don't access the pointer after freeing it
            const embedder_data = opaque_ptr.data;
            const the_allocator = opaque_ptr.allocator;
            c.JS_FreeRuntime(self.asQuickJS());
            the_allocator.destroy(opaque_ptr);
            return embedder_data;
        }

        /// Create a new context using the provided embedder data (not necessarily the same as the
        /// runtime's embedder data).
        ///
        /// If you don't need any extra embedder data associated with the context, pass {} to use
        /// void type. Use context.runtime().data() to recover the runtime embedder data
        /// if you only have the context.
        pub fn newContext(
            self: *Self,
            context_embedder_data: anytype,
        ) Allocator.Error!*Context(EmbedderData, @TypeOf(context_embedder_data)) {
            const quickjs_ptr = c.JS_NewContext(self.asQuickJS()) orelse return error.OutOfMemory;
            errdefer c.JS_FreeContext(quickjs_ptr);
            if (@TypeOf(context_embedder_data) != void) {
                // store the embedder data on the heap so we have a stable reference to it
                const data_ptr = self.getOpaque().allocator.create(@TypeOf(context_embedder_data));
                data_ptr.* = context_embedder_data;
                c.JS_SetContextOpaque(quickjs_ptr, @ptrCast(data_ptr));
            }
            return @ptrCast(quickjs_ptr);
        }
    };
}

pub const JsError = error{PendingException};

pub const EvalFlags = packed struct(c_int) {
    type: enum(u1) {
        /// Evaluate as global code
        global,
        /// Evaluate as module code
        module,
    } = .global,
    _pad1: enum(u2) { zero } = .zero,
    /// Force strict mode
    strict: bool = false,
    _pad2: enum(u1) { zero } = .zero,
    /// Compile but do not run. The result is an object with a
    /// JS_TAG_FUNCTION_BYTECODE or JS_TAG_MODULE tag. It can be executed
    /// with JS_EvalFunction().
    compile_only: bool = false,
    /// Don't include the stack frames before this eval in the Error() backtraces
    backtrace_barrier: bool = false,
    /// Allow top-level await in normal script. JS_Eval() returns a
    /// promise. Only allowed with JS_EVAL_TYPE_GLOBAL
    @"async": bool = false,
    _pad3: enum(u24) { zero } = .zero,

    // check that bit offsets are correct
    comptime {
        assert(c.JS_EVAL_TYPE_GLOBAL == @as(c_int, @bitCast(EvalFlags{})));
        assert(c.JS_EVAL_TYPE_MODULE == @as(c_int, @bitCast(EvalFlags{ .type = .module })));
        assert(c.JS_EVAL_FLAG_STRICT == @as(c_int, @bitCast(EvalFlags{ .strict = true })));
        assert(c.JS_EVAL_FLAG_COMPILE_ONLY == @as(c_int, @bitCast(EvalFlags{ .compile_only = true })));
        assert(c.JS_EVAL_FLAG_BACKTRACE_BARRIER == @as(c_int, @bitCast(EvalFlags{ .backtrace_barrier = true })));
        assert(c.JS_EVAL_FLAG_ASYNC == @as(c_int, @bitCast(EvalFlags{ .@"async" = true })));
    }
};

pub const ExceptionOrValue = union(enum) {
    value: Value,
    exception: Value,

    fn init(ctx: anytype, quickjs_value: c.JSValue) ExceptionOrValue {
        comptime mustBeContextPtr(@TypeOf(ctx));
        return if (c.JS_IsException(quickjs_value) == 0)
            .{ .value = Value.init(quickjs_value) }
        else
            .{ .exception = ctx.catchException().? };
    }

    /// If this is an exception, re-throw it in the provided context and return error.JsError.
    /// Enables the pattern `const result = try jsCall(...).rethrow(ctx)` for functions that call
    /// code that may throw but want to propagate exceptions rather than handling them.
    pub fn rethrow(self: ExceptionOrValue, ctx: anytype) JsError!Value {
        comptime mustBeContextPtr(@TypeOf(ctx));
        switch (self) {
            .exception => |ex| {
                ctx.throw(ex);
                return error.PendingException;
            },
            .value => |value| return value,
        }
    }
};

pub fn Context(comptime RuntimeEmbedderData: type, comptime ContextEmbedderData: type) type {
    return opaque {
        const Self = @This();
        pub const is_context = true;

        /// Get self as a pointer to the QuickJS struct
        fn asQuickJS(self: *Self) *c.JSContext {
            return @ptrCast(self);
        }

        /// Access the embedder data passed into Runtime.newContext()
        pub fn data(self: *Self) *ContextEmbedderData {
            if (ContextEmbedderData == void) @compileError("Context was not created with any embedder data");
            return @alignCast(@ptrCast(c.JS_GetContextOpaque(self.asQuickJS()).?));
        }

        /// Access the runtime this context was created in
        pub fn runtime(self: *Self) *Runtime(RuntimeEmbedderData) {
            return @ptrCast(c.JS_GetRuntime(self.asQuickJS()).?);
        }

        /// Frees memory used by the context, and returns the data that had been associated with it
        pub fn deinit(self: *Self) ContextEmbedderData {
            const embedder_data: ContextEmbedderData = if (ContextEmbedderData == void) {} else self.data().*;
            c.JS_FreeContext(self.asQuickJS());
            return embedder_data;
        }

        /// Evaluates a string of JavaScript source in the context
        pub fn eval(self: *Self, code: [:0]const u8, filename: [:0]const u8, flags: EvalFlags) ExceptionOrValue {
            const result = c.JS_Eval(self.asQuickJS(), code.ptr, code.len, filename.ptr, @bitCast(flags));
            return ExceptionOrValue.init(self, result);
        }

        /// Get and remove the pending exception, if it exists.
        pub fn catchException(self: *Self) ?Value {
            return if (c.JS_HasException(self.asQuickJS()) == 0)
                null
            else
                Value.init(c.JS_GetException(self.asQuickJS()));
        }

        /// Throw a JavaScript exception
        pub fn throw(self: *Self, exception: Value) void {
            _ = c.JS_Throw(self.asQuickJS(), exception.value);
        }

        pub fn newCFunction(self: *Self, func: *const c.JSCFunction, name: [:0]const u8, length: i32) ExceptionOrValue {
            const result = c.JS_NewCFunction(self.asQuickJS(), func, name.ptr, length);
            return ExceptionOrValue.init(self, result);
        }

        pub fn globalObject(self: *Self) Value {
            return Value.init(c.JS_GetGlobalObject(self.asQuickJS()));
        }
    };
}

pub fn mustBeContextPtr(comptime T: type) void {
    const ok = switch (@typeInfo(T)) {
        .pointer => |p| p.size == .One and @hasDecl(p.child, "is_context"),
        else => |_| false,
    };
    if (!ok) @compileError("Expected a pointer to Context, got " ++ @typeName(T));
}

/// Tags with a reference count are negative
pub const Tag = enum(c_int) {
    big_int = c.JS_TAG_BIG_INT,
    symbol = c.JS_TAG_SYMBOL,
    string = c.JS_TAG_STRING,
    /// internal
    module = c.JS_TAG_MODULE,
    /// internal
    function_bytecode = c.JS_TAG_FUNCTION_BYTECODE,
    object = c.JS_TAG_OBJECT,

    int = c.JS_TAG_INT,
    bool = c.JS_TAG_BOOL,
    null = c.JS_TAG_NULL,
    undefined = c.JS_TAG_UNDEFINED,
    uninitialized = c.JS_TAG_UNINITIALIZED,
    catch_offset = c.JS_TAG_CATCH_OFFSET,
    /// Sentinel indicating that code has thrown a JS exception instead of returning a value.
    /// The value thrown can be accessed from the Context.
    exception = c.JS_TAG_EXCEPTION,
    float64 = c.JS_TAG_FLOAT64,

    /// If JS_NAN_BOXING is defined then larger tags are also float64
    _,

    /// First negative tag
    pub const first: Tag = @enumFromInt(c.JS_TAG_FIRST);
};

/// The result of a JavaScript expression. May be an Error object but not an exception.
pub const Value = extern struct {
    value: c.JSValue,

    fn init(quickjs_value: c.JSValue) Value {
        assert(quickjs_value.tag != @intFromEnum(Tag.exception));
        return .{ .value = quickjs_value };
    }

    pub fn tag(self: Value) Tag {
        return @enumFromInt(@as(c_int, @intCast(self.value.tag)));
    }

    /// Only works if typeof value == 'number'
    pub fn asNumber(self: Value) ?f64 {
        return if (self.asFloat64()) |f|
            f
        else if (self.asInt()) |i|
            @floatFromInt(i)
        else
            null;
    }

    /// Only works if the value is represented internally as a float, not an integer
    pub fn asFloat64(self: Value) ?f64 {
        return if (self.tag() == .float64)
            c.JS_VALUE_GET_FLOAT64(self.value)
        else
            null;
    }

    pub fn asInt(self: Value) ?i32 {
        return if (self.tag() == .int)
            c.JS_VALUE_GET_INT(self.value)
        else
            null;
    }

    pub fn toCString(self: Value, ctx: anytype) JsError!CString {
        comptime mustBeContextPtr(@TypeOf(ctx));
        var len: usize = undefined;
        const ptr = c.JS_ToCStringLen(ctx.asQuickJS(), &len, self.value) orelse return error.PendingException;
        return .{ .slice = ptr[0..len] };
    }

    pub fn deinit(self: Value, ctx: anytype) void {
        comptime mustBeContextPtr(@TypeOf(ctx));
        c.JS_FreeValue(ctx.asQuickJS(), self.value);
    }
};

/// A UTF-8 encoded string owned by a QuickJS context
pub const CString = struct {
    slice: []const u8,

    pub fn deinit(self: CString, ctx: anytype) void {
        comptime mustBeContextPtr(@TypeOf(ctx));
        c.JS_FreeCString(ctx.asQuickJS(), self.slice.ptr);
    }
};

pub const CFunctionType = enum(u8) {
    generic = c.JS_CFUNC_generic,
    generic_magic = c.JS_CFUNC_generic_magic,
    constructor = c.JS_CFUNC_constructor,
    constructor_magic = c.JS_CFUNC_constructor_magic,
    constructor_or_func = c.JS_CFUNC_constructor_or_func,
    constructor_or_func_magic = c.JS_CFUNC_constructor_or_func_magic,
    f64_to_f64 = c.JS_CFUNC_f_f,
    f64_pair_to_f64 = c.JS_CFUNC_f_f_f,
    getter = c.JS_CFUNC_getter,
    setter = c.JS_CFUNC_setter,
    getter_magic = c.JS_CFUNC_getter_magic,
    setter_magic = c.JS_CFUNC_setter_magic,
    iterator_next = c.JS_CFUNC_iterator_next,
};

// TODO make generic over context/rt embedder data?
pub const CFunction = union(CFunctionType) {
    generic: *const c.JSCFunction,
    generic_magic: *const fn (ctx: *c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*]c.JSValue, magic: c_int) callconv(.C) c.JSValue,
    constructor: *const c.JSCFunction,
    constructor_magic: *const fn (ctx: *c.JSContext, new_target: c.JSValue, argc: c_int, argv: [*]c.JSValue, magic: c_int) callconv(.C) c.JSValue,
    constructor_or_func: *const c.JSCFunction,
    f64_to_f64: *const fn (f64) callconv(.C) f64,
    f64_pair_to_f64: *const fn (f64, f64) callconv(.C) f64,
    getter: *const fn (ctx: *c.JSContext, this_val: c.JSValue) callconv(.C) c.JSValue,
    setter: *const fn (ctx: *c.JSContext, this_val: c.JSValue, val: c.JSValue) callconv(.C) c.JSValue,
    getter_magic: *const fn (ctx: *c.JSContext, this_val: c.JSValue, magic: c_int) callconv(.C) c.JSValue,
    setter_magic: *const fn (ctx: *c.JSContext, this_val: c.JSValue, val: c.JSValue, magic: c_int) callconv(.C) c.JSValue,
    iterator_next: *const fn (ctx: *c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*]c.JSValue, pdone: *c_int, magic: c_int) callconv(.C) c.JSValue,
};

pub const PropertyFlags = packed struct(u8) {
    configurable: bool,
    writable: bool,
    enumerable: bool,
    /// Used internally in Arrays
    _length: enum(u1) { false } = .false,
    get_set: bool,

    _pad: enum(u3) { zero } = .zero,

    pub const normal: PropertyFlags = .{
        .configurable = false,
        .writable = false,
        .enumerable = false,
        .get_set = false,
    };

    /// Configurable, writable, and enumerable
    pub const c_w_e: PropertyFlags = .{
        .configurable = true,
        .writable = true,
        .enumerable = true,
        .get_set = false,
    };

    // check bit offsets are correct
    comptime {
        assert(@as(u8, @bitCast(PropertyFlags.normal)) == c.JS_PROP_NORMAL);
        assert(@as(u8, @bitCast(PropertyFlags.c_w_e)) == c.JS_PROP_C_W_E);

        for (.{
            "configurable",
            "writable",
            "enumerable",
            "get_set",
        }, .{
            c.JS_PROP_CONFIGURABLE,
            c.JS_PROP_WRITABLE,
            c.JS_PROP_ENUMERABLE,
            c.JS_PROP_GETSET,
        }) |zig_flag_name, c_flag| {
            var flags = PropertyFlags.normal;
            @field(flags, zig_flag_name) = true;
            assert(@as(u8, @bitCast(flags)) == c_flag);
        }
    }
};

pub const PropertyDefinitionType = enum(u8) {
    c_function = c.JS_DEF_CFUNC,
    c_get_set = c.JS_DEF_CGETSET,
    c_get_set_with_magic = c.JS_DEF_CGETSET_MAGIC,
    string = c.JS_DEF_PROP_STRING,
    i32 = c.JS_DEF_PROP_INT32,
    i64 = c.JS_DEF_PROP_INT64,
    f64 = c.JS_DEF_PROP_DOUBLE,
    undefined = c.JS_DEF_PROP_UNDEFINED,
    object = c.JS_DEF_OBJECT,
    alias = c.JS_DEF_ALIAS,
};

pub const PropertyListEntry = struct {
    name: [:0]const u8,
    flags: PropertyFlags,
    definition: union(PropertyDefinitionType) {
        c_function: struct {
            length: u8,
            magic: i16,
            function: CFunction,
        },
        c_get_set: struct {
            getter: *const fn (ctx: *c.JSContext, this_val: c.JSValue) callconv(.C) c.JSValue,
            setter: *const fn (ctx: *c.JSContext, this_val: c.JSValue, val: c.JSValue) callconv(.C) c.JSValue,
        },
        c_get_set_with_magic: struct {
            magic: i16,
            getter: *const fn (ctx: *c.JSContext, this_val: c.JSValue, magic: c_int) callconv(.C) c.JSValue,
            setter: *const fn (ctx: *c.JSContext, this_val: c.JSValue, val: c.JSValue, magic: c_int) callconv(.C) c.JSValue,
        },
        string: [:0]const u8,
        i32: i32,
        i64: i64,
        f64: f64,
        undefined: void,
        object: []const PropertyListEntry,
        alias: [:0]const u8,
    },
};
