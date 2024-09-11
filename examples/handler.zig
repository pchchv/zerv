// This example demonstrates using a custom Handler.
// It shows how to have global state
// (a counter is demonstrated here, but it could be a more complex structure involving things like a database pool)
// and how to define handlers for not found and errors.

const zerv = @import("zerv");
const std = @import("std");

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
