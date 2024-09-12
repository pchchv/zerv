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
