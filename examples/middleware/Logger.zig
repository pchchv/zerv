// This is a sample middleware

// Generally, using a custom handler with a dispatcher method provides the
// most flexibility and should be the first approach
// (see dispatcher.zig for an example).

// Middleware provides an alternative way
// to manage request/response and is well suited if different middleware
// (or middleware configurations)
// are needed for different routes.

const Logger = @This();

// Must defined a pub config structure,
// even if it's empty.
pub const Config = struct {
    query: bool,
};

// Must define an `init` method,
// which will accept your Config Alternatively,
// you can define a init(config: Config, mc: zerv.MiddlewareConfig)
// here mc will give you access to the server's allocator and arena
pub fn init(config: Config) !Logger {
    return .{
        .query = config.query,
    };
}

// optionally you can define an "deinit" method
pub fn deinit() void {}
