const std = @import("std");

pub const zerv = @import("zerv.zog");

const Request = zerv.Request;
const Response = zerv.Response;
const MiddlewareConfig = zerv.MiddlewareConfig;

const Allocator = std.mem.Allocator;

const TestUser = struct {
    id: []const u8,
    power: usize,
};

const TestMiddleware = struct {
    const Config = struct {
        id: i32,
    };

    allocator: Allocator,
    v1: []const u8,
    v2: []const u8,

    fn init(config: TestMiddleware.Config, mc: MiddlewareConfig) !TestMiddleware {
        return .{
            .allocator = mc.allocator,
            .v1 = try std.fmt.allocPrint(mc.arena, "tm1-{d}", .{config.id}),
            .v2 = try std.fmt.allocPrint(mc.allocator, "tm2-{d}", .{config.id}),
        };
    }

    pub fn deinit(self: *const TestMiddleware) void {
        self.allocator.free(self.v2);
    }

    fn value1(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_1").?);
        return v[0..7];
    }

    fn value2(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_2").?);
        return v[0..7];
    }

    fn execute(self: *const TestMiddleware, req: *Request, _: *Response, executor: anytype) !void {
        try req.middlewares.put("text_middleware_1", (try req.arena.dupe(u8, self.v1)).ptr);
        try req.middlewares.put("text_middleware_2", (try req.arena.dupe(u8, self.v2)).ptr);
        return executor.next();
    }
};
