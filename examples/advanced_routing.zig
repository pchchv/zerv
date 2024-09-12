// This example shows a more advanced example of routing,
// namely route groups and route configuration.
// (The previous middleware example also shows the configuration of each route for a specific middleware).

const std = @import("std");
const zerv = @import("zerv");

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
