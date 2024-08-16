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

    pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
        try std.json.stringify(value, options, Writer.init(self));
        self.content_type = zerv.ContentType.JSON;
    }

    pub fn headerOpts(self: *Response, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        const n = if (opts.dupe_name) try self.arena.dupe(u8, name) else name;
        const v = if (opts.dupe_name) try self.arena.dupe(u8, value) else name;
        self.headers.add(n, v);
    }

    fn prepareHeader(self: *Response) ![]const u8 {
        const headers = &self.headers;
        const names = headers.keys[0..headers.len];
        const values = headers.values[0..headers.len];
        var len: usize = 0;
        for (names, values) |name, value| {
            // +4 for the colon, space and trailer
            len += name.len + value.len + 4;
        }

        // +200 gives us enough space to fit:
        // status/first line
        // longest supported built-in content type
        // (for a custom content type,
        // it would have been set via res.header(...) call,
        // so would be included in `len)
        // The Content-Length header or the Transfer-Encoding header.
        var buf = try self.arena.alloc(u8, len + 200);
        var pos: usize = "HTTP/1.1 XXX \r\n".len;
        switch (self.status) {
            inline 100...103, 200...208, 226, 300...308, 400...418, 421...426, 428, 429, 431, 451, 500...511 => |status| @memcpy(buf[0..15], std.fmt.comptimePrint("HTTP/1.1 {d} \r\n", .{status})),
            else => |s| {
                const HTTP1_1 = "HTTP/1.1 ";
                const l = HTTP1_1.len;
                @memcpy(buf[0..l], HTTP1_1);
                pos = l + writeInt(buf[l..], @as(u32, s));
                @memcpy(buf[pos..][0..3], " \r\n");
                pos += 3;
            },
        }

        if (self.content_type) |ct| {
            const content_type: ?[]const u8 = switch (ct) {
                .BINARY => "Content-Type: application/octet-stream\r\n",
                .CSS => "Content-Type: text/css\r\n",
                .CSV => "Content-Type: text/csv\r\n",
                .EOT => "Content-Type: application/vnd.ms-fontobject\r\n",
                .EVENTS => "Content-Type: text/event-stream\r\n",
                .GIF => "Content-Type: image/gif\r\n",
                .GZ => "Content-Type: application/gzip\r\n",
                .HTML => "Content-Type: text/html\r\n",
                .ICO => "Content-Type: image/vnd.microsoft.icon\r\n",
                .JPG => "Content-Type: image/jpeg\r\n",
                .JS => "Content-Type: application/javascript\r\n",
                .JSON => "Content-Type: application/json\r\n",
                .OTF => "Content-Type: font/otf\r\n",
                .PDF => "Content-Type: application/pdf\r\n",
                .PNG => "Content-Type: image/png\r\n",
                .SVG => "Content-Type: image/svg+xml\r\n",
                .TAR => "Content-Type: application/x-tar\r\n",
                .TEXT => "Content-Type: text/plain\r\n",
                .TTF => "Content-Type: font/ttf\r\n",
                .WASM => "Content-Type: application/wasm\r\n",
                .WEBP => "Content-Type: image/webp\r\n",
                .WOFF => "Content-Type: font/woff\r\n",
                .WOFF2 => "Content-Type: font/woff2\r\n",
                .XML => "Content-Type: application/xml\r\n",
                .UNKNOWN => null,
            };
            if (content_type) |value| {
                const end = pos + value.len;
                @memcpy(buf[pos..end], value);
                pos = end;
            }
        }

        if (self.keepalive == false) {
            const CLOSE_HEADER = "Connection: Close\r\n";
            const end = pos + CLOSE_HEADER.len;
            @memcpy(buf[pos..end], CLOSE_HEADER);
            pos = end;
        }

        for (names, values) |name, value| {
            {
                // write the name
                const end = pos + name.len;
                @memcpy(buf[pos..end], name);
                pos = end;
                buf[pos] = ':';
                buf[pos + 1] = ' ';
                pos += 2;
            }

            {
                // write the value + trailer
                const end = pos + value.len;
                @memcpy(buf[pos..end], value);
                pos = end;
                buf[pos] = '\r';
                buf[pos + 1] = '\n';
                pos += 2;
            }
        }

        const buffer_pos = self.buffer.pos;
        const body_len = if (buffer_pos > 0) buffer_pos else self.body.len;
        if (body_len > 0) {
            const CONTENT_LENGTH = "Content-Length: ";
            var end = pos + CONTENT_LENGTH.len;
            @memcpy(buf[pos..end], CONTENT_LENGTH);
            pos = end;

            pos += writeInt(buf[pos..], @intCast(body_len));
            end = pos + 4;
            @memcpy(buf[pos..end], "\r\n\r\n");
            return buf[0..end];
        }

        const fin = blk: {
            // For chunked, we end with a single \r\n because the call to res.chunk()
            // prepends a \r\n. Hence,for the first chunk, we'll have the correct \r\n\r\n
            if (self.chunked) break :blk "Transfer-Encoding: chunked\r\n";
            if (self.content_type == .EVENTS) break :blk "\r\n";
            break :blk "Content-Length: 0\r\n\r\n";
        };

        const end = pos + fin.len;
        @memcpy(buf[pos..end], fin);
        return buf[0..end];
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

fn writeInt(into: []u8, value: u32) usize {
    const small_strings = "00010203040506070809" ++
        "10111213141516171819" ++
        "20212223242526272829" ++
        "30313233343536373839" ++
        "40414243444546474849" ++
        "50515253545556575859" ++
        "60616263646566676869" ++
        "70717273747576777879" ++
        "80818283848586878889" ++
        "90919293949596979899";

    var v = value;
    var i: usize = 10;
    var buf: [10]u8 = undefined;
    while (v >= 100) {
        const digits = v % 100 * 2;
        v /= 100;
        i -= 2;
        buf[i + 1] = small_strings[digits + 1];
        buf[i] = small_strings[digits];
    }

    {
        const digits = v * 2;
        i -= 1;
        buf[i] = small_strings[digits + 1];
        if (v >= 10) {
            i -= 1;
            buf[i] = small_strings[digits];
        }
    }

    const l = buf.len - i;
    @memcpy(into[0..l], buf[i..]);
    return l;
}
