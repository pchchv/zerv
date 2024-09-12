// This example shows how to use and create middleware.
// There is a crossover between what can be achieved with a custom dispatching and configuration function for each route
// (shown in the next example)
// and middleware.
// For an example of writing middleware,
// see middleware/Logger.zig.

const std = @import("std");
const zerv = @import("zerv");

const Logger = @import("middleware/Logger.zig");

const PORT = 8806;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try zerv.Server(void).init(allocator, .{ .port = PORT }, {});

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    // creates an instance of the middleware with the given configuration
    // see example/middleware/Logger.zig
    const logger = try server.middleware(Logger, .{ .query = true });

    var router = server.router(.{});

    // Apply middleware to all routes created from this point on
    router.middlewares = &.{logger};

    router.get("/", index, .{});
    router.get("/other", other, .{ .middlewares = &.{} });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *zerv.Request, res: *zerv.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\<p>There's overlap between a custom dispatch function and middlewares.
        \\<p>This page includes the example Logger middleware, so requesting it logs information.
        \\<p>The <a href="/other">other</a> endpoint uses a custom route config which
        \\   has no middleware, effectively disabling the Logger for that route.
    ;
}

fn other(_: *zerv.Request, res: *zerv.Response) !void {
    // Called with a custom config which had no middlewares
    // (effectively disabling the logging middleware)
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because the Logger middleware is disabled.
    ;
}
