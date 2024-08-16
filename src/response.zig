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

    // std.io.Writer.
    pub const Writer = struct {
        res: *Response,

        pub const Error = Allocator.Error;
        pub const IOWriter = std.io.Writer(Writer, error{OutOfMemory}, Writer.write);

        fn init(res: *Response) Writer {
            return .{ .res = res };
        }

        pub fn print(self: Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
            return std.fmt.format(self, format, args);
        }

        pub fn write(self: Writer, data: []const u8) Allocator.Error!usize {
            try self.writeAll(data);
            return data.len;
        }

        pub fn writeByte(self: Writer, b: u8) !void {
            var buf = try self.ensureSpace(1);
            const pos = buf.pos;
            buf.data[pos] = b;
            buf.pos = pos + 1;
        }

        pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
            var buf = try self.ensureSpace(n);
            var data = buf.data;
            const pos = buf.pos;
            for (pos..pos + n) |i| {
                data[i] = b;
            }
            buf.pos = pos + n;
        }

        pub fn writeBytesNTimes(self: Writer, bytes: []const u8, n: usize) !void {
            const l = bytes.len * n;
            var buf = try self.ensureSpace(l);
            var pos = buf.pos;
            var data = buf.data;
            for (0..n) |_| {
                const end_pos = pos + bytes.len;
                @memcpy(data[pos..end_pos], bytes);
                pos = end_pos;
            }
            buf.pos = l;
        }

        pub fn writeAll(self: Writer, data: []const u8) !void {
            var buf = try self.ensureSpace(data.len);
            const pos = buf.pos;
            const end_pos = pos + data.len;
            @memcpy(buf.data[pos..end_pos], data);
            buf.pos = end_pos;
        }

        pub fn truncate(self: Writer, n: usize) void {
            const buf = &self.res.buffer;
            const pos = buf.pos;
            const to_truncate = if (pos > n) n else pos;
            buf.pos = pos - to_truncate;
        }

        fn ensureSpace(self: Writer, n: usize) !*Buffer {
            const res = self.res;
            var buf = &res.buffer;
            const pos = buf.pos;
            const required_capacity = pos + n;

            const data = buf.data;
            if (data.len > required_capacity) {
                return buf;
            }

            var new_capacity = data.len;
            while (true) {
                new_capacity +|= new_capacity / 2 + 8;
                if (new_capacity >= required_capacity) break;
            }

            const new = try res.arena.alloc(u8, new_capacity);
            if (pos > 0) {
                @memcpy(new[0..pos], data[0..pos]);
                // Reasonable chance that the last allocation was buf to try freeing it
                // (ArenaAllocator's free function doesn't work unless the last allocation is freed).
                res.arena.free(data);
            }
            buf.data = new;
            return buf;
        }
    };

    pub const HeaderOpts = struct {
        dupe_name: bool = false,
        dupe_value: bool = false,
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

    pub fn headerOpts(self: *Response, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        const n = if (opts.dupe_name) try self.arena.dupe(u8, name) else name;
        const v = if (opts.dupe_name) try self.arena.dupe(u8, value) else name;
        self.headers.add(n, v);
    }

    pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
        try std.json.stringify(value, options, Writer.init(self));
        self.content_type = zerv.ContentType.JSON;
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
