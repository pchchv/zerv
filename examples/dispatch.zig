// This example uses a custom dispatch method on handler for greater control in how actions are executed.

const std = @import("std");
const zerv = @import("zerv");

const PORT = 8803;

const Handler = struct {
    // In addition to the special "notFound" and "uncaughtError" shown in example 2
    // the special "dispatch" method can be used to gain more control over request handling.
    pub fn dispatch(self: *Handler, action: zerv.Action(*Handler), req: *zerv.Request, res: *zerv.Response) !void {
        // Custom dispatch lets us add a log + timing for every request zerv supports middlewares,
        // but in many cases, having a dispatch is good enough and is much more straightforward.
        var start = try std.time.Timer.start();
        // Don't _have_ to call the action if don't want to.
        // For example could do authentication and set the response directly on error.
        try action(self, req, res);

        std.debug.print("ts={d} us={d} path={s}\n", .{ std.time.timestamp(), start.lap() / 1000, req.url.path });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{};
    var server = try zerv.Server(*Handler).init(allocator, .{ .port = PORT }, &handler);

    defer server.deinit();

    // ensures a clean shutdown,
    // finishing off any existing requests see shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    router.get("/", index, .{});
    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // starts the server,
    // this is blocking
    try server.listen();
}

fn index(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    res.body =
        \\ If defied, the dispatch method will be invoked for every request with a matching route.
        \\ It is up to dispatch to decide how/if the action should be called. While zerv
        \\ supports middleware, most cases can be more easily and cleanly handled with
        \\ a custom dispatch alone (you can always use both middlewares and a custom dispatch though).
        \\
        \\ Check out the console, our custom dispatch function times & logs each request.
    ;
}
