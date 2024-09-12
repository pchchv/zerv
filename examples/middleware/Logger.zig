// This is a sample middleware

// Generally, using a custom handler with a dispatcher method provides the
// most flexibility and should be the first approach
// (see dispatcher.zig for an example).

// Middleware provides an alternative way
// to manage request/response and is well suited if different middleware
// (or middleware configurations)
// are needed for different routes.

const std = @import("std");
const zerv = @import("zerv");

const Logger = @This();

query: bool,

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

// Must define an `execute` method.
// `self` doesn't have to be `const`,
// but you're responsible for making your middleware thread-safe.
pub fn execute(self: *const Logger, req: *zerv.Request, res: *zerv.Response, executor: anytype) !void {
    // Better to use an std.time.Timer to measure elapsed time
    // but we need the "start" time for our log anyways, so while this might occasionally
    // report wrong/strange "elapsed" time, it's simpler to do.
    const start = std.time.microTimestamp();

    defer {
        const elapsed = std.time.microTimestamp() - start;
        std.log.info("{d}\t{s}?{s}\t{d}\t{d}us", .{ start, req.url.path, if (self.query) req.url.query else "", res.status, elapsed });
    }

    // If you don't call executor.next(), there will be no further processing of
    // the request and we'll go straight to writing the response.
    return executor.next();
}
