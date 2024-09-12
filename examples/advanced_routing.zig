// This example shows a more advanced example of routing,
// namely route groups and route configuration.
// (The previous middleware example also shows the configuration of each route for a specific middleware).

const std = @import("std");
const zerv = @import("zerv");

const PORT = 8807;

const Handler = struct {
    log: bool,

    // special dispatch set in the info route
    pub fn infoDispatch(h: *Handler, action: zerv.Action(*Handler), req: *zerv.Request, res: *zerv.Response) !void {
        return action(h, req, res);
    }

    pub fn dispatch(h: *Handler, action: zerv.Action(*Handler), req: *zerv.Request, res: *zerv.Response) !void {
        try action(h, req, res);
        if (h.log) {
            std.debug.print("ts={d} path={s} status={d}\n", .{ std.time.timestamp(), req.url.path, res.status });
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var default_handler = Handler{
        .log = true,
    };

    var nolog_handler = Handler{
        .log = false,
    };

    var server = try zerv.Server(*Handler).init(allocator, .{ .port = PORT }, &default_handler);

    defer server.deinit();

    // ensures a clean shutdown,
    // finishing off any existing requests
    // see shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    router.get("/", index, .{});

    // It is possible to define a dispatch function for each route.
    // It will be used instead of Handler.dispatch.
    // But unfortunately, each dispatch method must have the same signature
    // (they must all take the same action type)
    router.get("/page1", page1, .{ .dispatcher = Handler.infoDispatch });

    // It is possible to define a handler instance for each route.
    // This will be used instead of the handler instance passed to the init method above.
    router.get("/page2", page2, .{ .handler = &nolog_handler });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn page1(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    // Called with a custom config which specified a custom dispatch method
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because a custom dispatch method is used
    ;
}

fn page2(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    // Called with a custom config which specified a custom handler instance
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because a custom handler instance is used
    ;
}

fn index(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\ <p>It's possible to define a custom dispatch method, custom handler instance and/or custom middleware per-route.
        \\ <p>It's also possible to create a route group, which is a group of routes who share a common prefix and/or a custom configration.
        \\ <ul>
        \\ <li><a href="/page1">page with custom dispatch</a>
        \\ <li><a href="/page2">page with custom handler</a>
    ;
}
