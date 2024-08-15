const std = @import("std");

const zerv = @import("zerv.zig");
const buffer = @import("buffer.zig");

const HTTPConn = @import("worker.zig").HTTPConn;
const KeyValue = @import("key_value.zig").KeyValue;

const Allocator = std.mem.Allocator;

const Self = @This();

pub const Response = struct {
    // zerv's wrapper around a stream, the brave can access the underlying .stream
    conn: *HTTPConn,
    // Where in body we're writing to. Used for dynamically writes to body, e.g.
    // via the json() or writer() functions
    pos: usize,
    // The status code to write.
    status: u16,
    // The response headers.
    // Using res.header(NAME, VALUE) is preferred.
    headers: KeyValue,
    // The content type. Use header("content-type", value) for a content type
    // which isn't available in the zerv.ContentType enum.
    content_type: ?zerv.ContentType,
    // An arena that will be reset at the end of each request. Can be used
    // internally by this framework. The application is also free to make use of
    // this arena. This is the same arena as request.arena.
    arena: Allocator,
    // whether or not we've already written the response
    written: bool,
    // whether or not we're in chunk transfer mode
    chunked: bool,
    // when false, the Connection: Close header is sent. This should not be set
    // directly, rather set req.keepalive = false.
    keepalive: bool,
    // The body to send. This is set directly, res.body = "Hello World".
    body: []const u8,
    // When the body is written to via the writer API (the json helper wraps
    // the writer api)
    buffer: Buffer,

    pub const State = Self.State;

    const Buffer = struct {
        pos: usize,
        data: []u8,
    };
};
