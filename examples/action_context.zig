// This example is very similar to 03_dispatch.zig,
// but shows how the action state can be a different type than the handler.

const RouteData = struct {
    restricted: bool,
};
