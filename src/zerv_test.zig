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
};
