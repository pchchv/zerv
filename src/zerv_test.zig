const std = @import("std");

pub const zerv = @import("zerv.zog");

const Request = zerv.Request;
const Response = zerv.Response;
const MiddlewareConfig = zerv.MiddlewareConfig;

const Allocator = std.mem.Allocator;

const TestMiddleware = struct {
    const Config = struct {
        id: i32,
    };

    allocator: Allocator,
    v1: []const u8,
    v2: []const u8,
};
