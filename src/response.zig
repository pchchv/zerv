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

    /// Should not be called directly, but initialized through a pool.
    pub fn init(arena: Allocator, conn: *HTTPConn) Response {
        return .{
            .pos = 0,
            .body = "",
            .conn = conn,
            .status = 200,
            .arena = arena,
            .buffer = Buffer{ .pos = 0, .data = "" },
            .chunked = false,
            .written = false,
            .keepalive = true,
            .content_type = null,
            .headers = conn.res_state.headers,
        };
    }

    pub fn disown(self: *Response) void {
        self.written = true;
        self.conn.handover = .disown;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.add(name, value);
    }

    pub fn startEventStream(self: *Response, ctx: anytype, comptime handler: fn (@TypeOf(ctx), std.net.Stream) void) !void {
        self.content_type = .EVENTS;
        self.headers.add("Cache-Control", "no-cache");
        self.headers.add("Connection", "keep-alive");

        const conn = self.conn;
        const stream = conn.stream;

        const header_buf = try self.prepareHeader();
        try stream.writeAll(header_buf);

        self.disown();

        const thread = try std.Thread.spawn(.{}, handler, .{ ctx, stream });
        thread.detach();
    }

    pub fn chunk(self: *Response, data: []const u8) !void {
        const conn = self.conn;
        const stream = conn.stream;
        if (!self.chunked) {
            self.chunked = true;
            const header_buf = try self.prepareHeader();
            try stream.writeAll(header_buf);
        }

        // enough for a 1TB chunk
        var buf: [16]u8 = undefined;
        buf[0] = '\r';
        buf[1] = '\n';

        const len = 2 + std.fmt.formatIntBuf(buf[2..], data.len, 16, .upper, .{});
        buf[len] = '\r';
        buf[len + 1] = '\n';

        var vec = [2]std.posix.iovec_const{
            .{ .len = len + 2, .base = &buf },
            .{ .len = data.len, .base = data.ptr },
        };
        try writeAllIOVec(self.conn, &vec);
    }
};

fn writeAllIOVec(conn: *HTTPConn, vec: []std.posix.iovec_const) !void {
    const socket = conn.stream.handle;
    var i: usize = 0;
    while (true) {
        var n = try std.posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}
