// Helpers for application developers to be able to mock request and parse responses.

const std = @import("std");

const t = @import("test.zig");
const zerv = @import("zerv.zig");

const Conn = @import("worker.zig").HTTPConn;
const Allocator = std.mem.Allocator;

pub const Testing = struct {
    _ctx: t.Context,
    conn: *Conn,
    req: *zerv.Request,
    res: *zerv.Response,
    arena: std.mem.Allocator,
    parsed_response: ?Response = null,

    pub const Response = struct {
        status: u16,
        raw: []const u8,
        body: []const u8,
        allocator: std.mem.Allocator,
        headers: std.StringHashMap([]const u8),
    };
};

const JsonComparer = struct {
    _arena: std.heap.ArenaAllocator,

    const Diff = struct {
        err: []const u8,
        path: []const u8,
        a: []const u8,
        b: []const u8,
    };

    fn init(allocator: Allocator) JsonComparer {
        return .{
            ._arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: JsonComparer) void {
        self._arena.deinit();
    }

fn isString(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .Slice => return ptr.child == u8,
            .One => switch (@typeInfo(ptr.child)) {
                .array => |arr| return arr.child == u8,
                else => return false,
            },
            else => return false,
        },
        .array => return false,
        else => return false,
    }
}
