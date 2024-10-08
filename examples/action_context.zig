// This example is very similar to 03_dispatch.zig,
// but shows how the action state can be a different type than the handler.

const std = @import("std");
const zerv = @import("zerv");

const PORT = 8804;

const RouteData = struct {
    restricted: bool,
};

const Env = struct {
    handler: *Handler,
    user: ?[]const u8,
};

const Handler = struct {
    // In dispatch example, action type was: zerv.Action(*Handler).
    // In this example, have changed it to: zerv.Action(*Env)
    // This allows handler to be a general app-wide "state" while actions received a request-specific context
    pub fn dispatch(self: *Handler, action: zerv.Action(*Env), req: *zerv.Request, res: *zerv.Response) !void {
        const user = (try req.query()).get("auth");

        // RouteData can be anything,
        // but since it's stored as a *const anyopaque you'll need to restore the type/alignment.

        // (You could also use a per-route handler, or middleware, to achieve the same thing.
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

    const restricted_route = &RouteData{ .restricted = true };

    // It is possible to log arbitrary data in a route,
    // which can be retrieved via req.route_data.
    // This data is stored as `*const anyopaque`.
    router.get("/", index, .{});
    router.get("/admin", admin, .{ .data = restricted_route });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *Env, _: *zerv.Request, res: *zerv.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\ <p>The <code>Handler.dispatch</code> method takes an <code>zerv.Action(*Env)</code>.
        \\ <p>This allows the handler method to create a request-specific value to pass into actions.
        \\ <p>For example, dispatch might load a User (using a request header value maybe) and make it available to the action.
        \\ <p>Goto <a href="/admin?auth=superuser">admin</a> to simulate a (very insecure) authentication.
    ;
}

// because of dispatch method, this can only be called when env.user != null
fn admin(env: *Env, _: *zerv.Request, res: *zerv.Response) !void {
    res.body = try std.fmt.allocPrint(res.arena, "Welcome to the admin portal, {s}", .{env.user.?});
}
