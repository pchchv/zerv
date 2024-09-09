// Helpers for application developers to be able to mock request and parse responses.

const std = @import("std");

const t = @import("test.zig");
const zerv = @import("zerv.zig");

const Conn = @import("worker.zig").HTTPConn;

pub const Testing = struct {
    _ctx: t.Context,
    conn: *Conn,
    req: *zerv.Request,
    res: *zerv.Response,
    arena: std.mem.Allocator,
    parsed_response: ?Response = null,
};
