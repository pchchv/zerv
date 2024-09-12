// This example show how to upgrade a request to websocket.

const std = @import("std");

// websocket.zig is verbose, let's limit it to err messages
pub const std_options = .{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .err },
} };
