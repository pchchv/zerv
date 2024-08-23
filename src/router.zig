const zerv = @import("zerv.zig");

pub fn Config(comptime Handler: type, comptime Action: type) type {
    const Dispatcher = zerv.Dispatcher(Handler, Action);
    return struct {
        handler: ?Handler = null,
        dispatcher: ?Dispatcher = null,
    };
}
