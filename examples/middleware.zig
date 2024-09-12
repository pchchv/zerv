// This example shows how to use and create middleware.
// There is a crossover between what can be achieved with a custom dispatching and configuration function for each route
// (shown in the next example)
// and middleware.
// For an example of writing middleware,
// see middleware/Logger.zig.

const zerv = @import("zerv");

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
