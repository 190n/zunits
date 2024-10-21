const std = @import("std");

pub const options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .js_alloc, .level = .info },
    },
};
