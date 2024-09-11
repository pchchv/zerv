// This example is very similar to 03_dispatch.zig,
// but shows how the action state can be a different type than the handler.

const zerv = @import("zerv");

const RouteData = struct {
    restricted: bool,
};

const Env = struct {
    handler: *Handler,
    user: ?[]const u8,
};

const Handler = struct {
    // In example_3, action type was: zerv.Action(*Handler).
    // In this example, have changed it to: zerv.Action(*Env)
    // This allows handler to be a general app-wide "state" while actions received a request-specific context
    pub fn dispatch(self: *Handler, action: zerv.Action(*Env), req: *zerv.Request, res: *zerv.Response) !void {
        const user = (try req.query()).get("auth");

        // RouteData can be anything,
        // but since it's stored as a *const anyopaque you'll need to restore the type/alignment.

        // (You could also use a per-route handler, or middleware,
        // to achieve the same thing.
        // Using route data is a bit ugly due to the type erasure but it can be convenient!).
        if (req.route_data) |rd| {
            const route_data: *const RouteData = @ptrCast(@alignCast(rd));
            if (route_data.restricted and (user == null or user.?.len == 0)) {
                res.status = 401;
                res.body = "permission denied";
                return;
            }
        }

        var env = Env{
            .user = user, // todo: this is not very good security!
            .handler = self,
        };

        try action(&env, req, res);
    }
};
