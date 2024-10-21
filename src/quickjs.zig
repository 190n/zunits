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

        pub fn create(allocator: Allocator, embedder_data: EmbedderData) Allocator.Error!*Self {
            // use the allocator to put the context on the heap, since we need a stable pointer
            const opaque_ptr = try allocator.create(Opaque);
            opaque_ptr.* = .{
                .data = embedder_data,
                .allocator = allocator,
            };
            // malloc functions expect a *Allocator for their context
            const runtime = c.JS_NewRuntime2(&malloc_functions, @ptrCast(&opaque_ptr.allocator)) orelse return error.OutOfMemory;
            c.JS_SetRuntimeOpaque(runtime, @ptrCast(opaque_ptr));
            return @ptrCast(runtime);
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
            const allocator = opaque_ptr.allocator;
            c.JS_FreeRuntime(self.asQuickJS());
            allocator.destroy(opaque_ptr);
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
        return if (c.JS_IsException(quickjs_value) == 0)
            .{ .value = Value.init(quickjs_value) }
        else
            .{ .exception = ctx.exception().? };
    }

    pub fn toError(self: ExceptionOrValue) JsError!Value {
        return switch (self) {
            .exception => |_| error.PendingException,
            .value => |value| value,
        };
    }
};

pub fn Context(comptime RuntimeEmbedderData: type, comptime ContextEmbedderData: type) type {
    return opaque {
        const Self = @This();

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

        /// Get the pending exception, if it exists
        pub fn exception(self: *Self) ?Value {
            return if (c.JS_HasException(self.asQuickJS()) == 0)
                null
            else
                Value.init(c.JS_GetException(self.asQuickJS()));
        }
    };
}

pub const Value = extern struct {
    value: c.JSValue,

    fn init(quickjs_value: c.JSValue) Value {
        assert(c.JS_IsException(quickjs_value) == 0);
        return .{ .value = quickjs_value };
    }

    pub fn toCString(self: Value, ctx: anytype) JsError!CString {
        var len: usize = undefined;
        const ptr = c.JS_ToCStringLen(ctx.asQuickJS(), &len, self.value) orelse return error.PendingException;
        return .{ .slice = ptr[0..len] };
    }

    pub fn deinit(self: Value, ctx: anytype) void {
        c.JS_FreeValue(ctx.asQuickJS(), self.value);
    }
};

/// A UTF-8 encoded string owned by a QuickJS context
pub const CString = struct {
    slice: []const u8,

    pub fn deinit(self: CString, ctx: anytype) void {
        c.JS_FreeCString(ctx.asQuickJS(), self.slice.ptr);
    }
};
