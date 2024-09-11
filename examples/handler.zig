// This example demonstrates using a custom Handler.
// It shows how to have global state
// (a counter is demonstrated here, but it could be a more complex structure involving things like a database pool)
// and how to define handlers for not found and errors.

const std = @import("std");
const zerv = @import("zerv");

const PORT = 8802;

const Handler = struct {
    _hits: usize = 0,

    // If the handler defines a special "notFound" function, it'll be called
    // when a request is made and no route matches.
    pub fn notFound(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
        res.status = 404;
        res.body = "NOPE!";
    }

    // If the handler defines the special "uncaughtError" function,
    // it'll be called when an action returns an error.
    // Note that this function takes an additional parameter (the error)
    // and returns a `void` rather than a `!void`.
    pub fn uncaughtError(_: *Handler, req: *zerv.Request, res: *zerv.Response, err: anyerror) void {
        std.debug.print("uncaught http error at {s}: {}\n", .{ req.url.path, err });

        // Alternative to res.content_type = .TYPE
        // useful for dynamic content types,
        // or content types not defined in zerv.ContentType
        res.headers.add("content-type", "text/html; charset=utf-8");

        res.status = 505;
        res.body = "<!DOCTYPE html>(╯°□°)╯︵ ┻━┻";
    }
};

pub fn hits(h: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    const count = @atomicRmw(usize, &h._hits, .Add, 1, .monotonic);

    // @atomicRmw returns the previous version so is
    // needed to +1 it to display the count includin this hit
    return res.json(.{ .hits = count + 1 }, .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // “Handler” is specified and,
    // as the last init parameter,
    // its instance is passed.
    var handler = Handler{};
    var server = try zerv.Server(*Handler).init(allocator, .{ .port = PORT }, &handler);

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    // register routes
    router.get("/", index, .{});
    router.get("/hits", hits, .{});
    router.get("/error", @"error", .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // starts the server,
    // this is blocking
    try server.listen();
}

fn index(_: *Handler, _: *zerv.Request, res: *zerv.Response) !void {
    res.body =
        \\<!DOCTYPE html>
        \\ <p>Except in very simple cases, you'll want to use a custom Handler.
        \\ <p>A custom Handler is how you share app-specific data with your actions (like a DB pool)
        \\    and define a custom not found and error function.
        \\ <p>Other examples show more advanced things you can do with a custom Handler.
        \\ <ul>
        \\ <li><a href="/hits">Shared global hit counter</a>
        \\ <li><a href="/not_found">Custom not found handler</a>
        \\ <li><a href="/error">Custom error  handler</a>
    ;
}

fn @"error"(_: *Handler, _: *zerv.Request, _: *zerv.Response) !void {
    return error.ActionError;
}
