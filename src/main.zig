const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("./quickjs.zig");

pub const std_options = @import("./std_options.zig").options;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = if (builtin.mode == .Debug)
        gpa.allocator()
    else if (builtin.target.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;

    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();
    const stderr_file = std.io.getStdErr();
    const stderr = stderr_file.writer();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        try stderr.print("usage: {s} <JavaScript code>\n", .{args[0]});
        return error.BadUsage;
    }

    const rt = try quickjs.Runtime(void).create(allocator, {});
    defer rt.deinit();

    const ctx = try rt.newContext({});
    defer ctx.deinit();

    const result = switch (ctx.eval(args[1], "main.js", .{})) {
        .value => |v| v,
        .exception => |exception| {
            defer exception.deinit(ctx);
            var str = try exception.toCString(ctx);
            defer str.deinit(ctx);
            try stderr.print("{s}\n", .{str.slice});
            return error.JsException;
        },
    };
    defer result.deinit(ctx);

    const str = try result.toCString(ctx);
    defer str.deinit(ctx);

    try stdout.print("{s}\n", .{str.slice});
}
