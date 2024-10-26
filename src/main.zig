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
    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    const rt = try quickjs.Runtime(void).create(allocator, {});
    defer rt.deinit();

    const ctx = try rt.newContext({});
    defer ctx.deinit();

    var line: [4096]u8 = undefined;
    while (stdin.readUntilDelimiter(line[0 .. line.len - 1], '\n')) |input| {
        line[input.len] = 0;
        const null_terminated_input = line[0..input.len :0];
        const result = switch (ctx.eval(null_terminated_input, "repl.js", .{})) {
            .value => |v| v,
            .exception => |exception| {
                defer exception.deinit(ctx);
                var str = try exception.toCString(ctx);
                defer str.deinit(ctx);
                try stderr.print("{s}\n", .{str.slice});
                continue;
            },
        };
        defer result.deinit(ctx);

        const str = try result.toCString(ctx);
        defer str.deinit(ctx);

        try stdout.print("{s}\n", .{str.slice});
    } else |e| switch (e) {
        error.EndOfStream => {},
        else => return e,
    }
}
