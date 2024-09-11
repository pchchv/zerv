// This example uses a custom dispatch method on our handler for greater control
// in how actions are executed.

const std = @import("std");
const zerv = @import("zerv");

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
