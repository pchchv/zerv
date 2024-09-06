const std = @import("std");

const t = @import("test.zig");
const zerv = @import("zerv.zig");
const Request = @import("request.zeg");

const Config = @import("config.zig").Config.Request;

const atoi = Request.atoi;
const allowedHeaderValueByte = Request.allowedHeaderValueByte;

test "atoi" {
    var buf: [5]u8 = undefined;
    for (0..99999) |i| {
        const n = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        try t.expectEqual(i, atoi(buf[0..n]).?);
    }

    try t.expectEqual(null, atoi(""));
    try t.expectEqual(null, atoi("392a"));
    try t.expectEqual(null, atoi("b392"));
    try t.expectEqual(null, atoi("3c92"));
}

test "allowedHeaderValueByte" {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('z' + 1)) |b| all[b] = true;
    for ('A'..('Z' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    for ([_]u8{ '_', ' ', ',', ':', ';', '.', ',', '\\', '/', '"', '\'', '?', '!', '(', ')', '{', '}', '[', ']', '@', '<', '>', '=', '-', '+', '*', '#', '$', '&', '`', '|', '~', '^', '%', '\t' }) |b| {
        all[b] = true;
    }
    for (128..255) |b| all[b] = true;

    for (all, 0..) |allowed, b| {
        try t.expectEqual(allowed, allowedHeaderValueByte(@intCast(b)));
    }
}

test "request: header too big" {
    try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\n\r\n", .{ .buffer_size = 17 });
    try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\nH: v\r\n\r\n", .{ .buffer_size = 23 });
}

test "request: parse headers" {
    defer t.reset();
    {
        try expectParseError(error.InvalidHeaderLine, "GET / HTTP/1.1\r\nHost\r\n", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
        try t.expectEqual(0, r.headers.len);
    }

    {
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\n\r\n", .{});

        try t.expectEqual(1, r.headers.len);
        try t.expectString("pondzpondz.com", r.headers.get("host").?);
    }

    {
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
        try t.expectEqual(3, r.headers.len);
        try t.expectString("pondzpondz.com", r.header("host").?);
        try t.expectString("Some-Value", r.header("misc").?);
        try t.expectString("none", r.header("authorization").?);
    }
}

test "request: parse method" {
    defer t.reset();
    {
        try expectParseError(error.UnknownMethod, "GETT / HTTP/1.1 ", .{});
        try expectParseError(error.UnknownMethod, " PUT / HTTP/1.1", .{});
    }

    {
        const r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.GET, r.method);
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.PUT, r.method);
    }

    {
        const r = try testParse("POST / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.POST, r.method);
    }

    {
        const r = try testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.HEAD, r.method);
    }

    {
        const r = try testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.PATCH, r.method);
    }

    {
        const r = try testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.DELETE, r.method);
    }

    {
        const r = try testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Method.OPTIONS, r.method);
    }
}

test "request: parse request target" {
    defer t.reset();
    {
        try expectParseError(error.InvalidRequestTarget, "GET NOPE", .{});
        try expectParseError(error.InvalidRequestTarget, "GET nope ", .{});
        try expectParseError(error.InvalidRequestTarget, "GET http://www.pondzpondz.com/test ", .{}); // this should be valid
        try expectParseError(error.InvalidRequestTarget, "PUT hello ", .{});
        try expectParseError(error.InvalidRequestTarget, "POST  /hello ", .{});
        try expectParseError(error.InvalidRequestTarget, "POST *hello ", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/", r.url.raw);
    }

    {
        const r = try testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/api/v2", r.url.raw);
    }

    {
        const r = try testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/API/v2?hack=true&over=9000%20!!", r.url.raw);
    }

    {
        const r = try testParse("PUT * HTTP/1.1\r\n\r\n", .{});
        try t.expectString("*", r.url.raw);
    }
}

test "request: parse protocol" {
    defer t.reset();
    {
        try expectParseError(error.UnknownProtocol, "GET / http/1.1\r\n", .{});
        try expectParseError(error.UnsupportedProtocol, "GET / HTTP/2.0\r\n", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
        try t.expectEqual(zerv.Protocol.HTTP10, r.protocol);
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(zerv.Protocol.HTTP11, r.protocol);
    }
}

test "request: canKeepAlive" {
    defer t.reset();
    {
        // implicitly keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(true, r.canKeepAlive());
    }

    {
        // explicitly keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
        try t.expectEqual(true, r.canKeepAlive());
    }

    {
        // explicitly not keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
        try t.expectEqual(false, r.canKeepAlive());
    }
}

test "request: query" {
    defer t.reset();
    {
        // none
        var r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(0, (try r.query()).len);
    }

    {
        // none with path
        var r = try testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(0, (try r.query()).len);
    }

    {
        // value-less
        var r = try testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(1, query.len);
        try t.expectString("", query.get("a").?);
        try t.expectEqual(null, query.get("b"));
    }

    {
        // single
        var r = try testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(1, query.len);
        try t.expectString("1", query.get("a").?);
        try t.expectEqual(null, query.get("b"));
    }

    {
        // multiple
        var r = try testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(3, query.len);
        try t.expectString("Tea", query.get("Teg").?);
        try t.expectString("over 9000$", query.get("it  IS").?);
        try t.expectString("", query.get("ha\tck").?);
    }
}

test "request: body content-length" {
    defer t.reset();
    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{ .max_body_size = 9 });
    }

    {
        // no body
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        try t.expectEqual(null, r.body());
        try t.expectEqual(null, r.body());
    }

    {
        // fits into static buffer
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
        try t.expectString("Over 9000!", r.body().?);
        try t.expectString("Over 9000!", r.body().?);
    }

    {
        // Requires dynamic buffer
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{ .buffer_size = 40 });
        try t.expectString("Over 9001!!", r.body().?);
        try t.expectString("Over 9001!!", r.body().?);
    }
}

// the query and body both (can) occupy space in our static buffer
test "request: query & body" {
    defer t.reset();

    // query then body
    var r = try testParse("POST /?search=keemun%20tea HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
    try t.expectString("keemun tea", (try r.query()).get("search").?);
    try t.expectString("Over 9000!", r.body().?);

    // results should be cached internally, but let's double check
    try t.expectString("keemun tea", (try r.query()).get("search").?);
}

test "request: fuzz" {
    // Have a bunch of data to allocate for testing,
    // like header names and values.
    // Easier to use this arena and reset it after each test run.
    const aa = t.arena.allocator();
    defer t.reset();

    var r = t.getRandom();
    const random = r.random();
    for (0..1000) |_| {
        // important to test with different buffer sizes, since there's a lot of
        // special handling for different cases (e.g the buffer is full and has
        // some of the body in it, so we need to copy that to a dynamically allocated
        // buffer)
        const buffer_size = random.uintAtMost(u16, 1024) + 1024;

        var ctx = t.Context.init(.{
            .request = .{ .buffer_size = buffer_size },
        });

        // enable fake mode, we don't go through a real socket, instead we go
        // through a fake one, that can simulate having data spread across multiple
        // calls to read()
        ctx.fake = true;
        defer ctx.deinit();

        // how many requests should we make on this 1 individual socket (simulating
        // keepalive AND the request pool)
        const number_of_requests = random.uintAtMost(u8, 10) + 1;

        for (0..number_of_requests) |_| {
            defer ctx.conn.keepalive(4096);
            const method = randomMethod(random);
            const url = t.randomString(random, aa, 20);

            ctx.write(method);
            ctx.write(" /");
            ctx.write(url);

            const number_of_qs = random.uintAtMost(u8, 4);
            if (number_of_qs != 0) {
                ctx.write("?");
            }

            var query = std.StringHashMap([]const u8).init(aa);
            for (0..number_of_qs) |_| {
                const key = t.randomString(random, aa, 20);
                const value = t.randomString(random, aa, 20);
                if (!query.contains(key)) {
                    query.put(key, value) catch unreachable;
                    ctx.write(key);
                    ctx.write("=");
                    ctx.write(value);
                    ctx.write("&");
                }
            }

            ctx.write(" HTTP/1.1\r\n");

            var headers = std.StringHashMap([]const u8).init(aa);
            for (0..random.uintAtMost(u8, 4)) |_| {
                const name = t.randomString(random, aa, 20);
                const value = t.randomString(random, aa, 20);
                if (!headers.contains(name)) {
                    headers.put(name, value) catch unreachable;
                    ctx.write(name);
                    ctx.write(": ");
                    ctx.write(value);
                    ctx.write("\r\n");
                }
            }

            var body: ?[]u8 = null;
            if (random.uintAtMost(u8, 4) == 0) {
                ctx.write("\r\n"); // no body
            } else {
                body = t.randomString(random, aa, 8000);
                const cl = std.fmt.allocPrint(aa, "{d}", .{body.?.len}) catch unreachable;
                headers.put("content-length", cl) catch unreachable;
                ctx.write("content-length: ");
                ctx.write(cl);
                ctx.write("\r\n\r\n");
                ctx.write(body.?);
            }

            var conn = ctx.conn;
            var fake_reader = ctx.fakeReader();
            while (true) {
                const done = try conn.req_state.parse(&fake_reader);
                if (done) break;
            }

            var request = Request.init(conn.arena.allocator(), conn);

            // assert the headers
            var it = headers.iterator();
            while (it.next()) |entry| {
                try t.expectString(entry.value_ptr.*, request.header(entry.key_ptr.*).?);
            }

            // assert the querystring
            var actualQuery = request.query() catch unreachable;
            it = query.iterator();
            while (it.next()) |entry| {
                try t.expectString(entry.value_ptr.*, actualQuery.get(entry.key_ptr.*).?);
            }

            const actual_body = request.body();
            if (body) |b| {
                try t.expectString(b, actual_body.?);
            } else {
                try t.expectEqual(null, actual_body);
            }
        }
    }
}

fn expectParseError(expected: anyerror, input: []const u8, config: Config) !void {
    var ctx = t.Context.init(.{ .request = config });
    defer ctx.deinit();

    ctx.write(input);
    try t.expectError(expected, ctx.conn.req_state.parse(ctx.stream));
}

fn testParse(input: []const u8, config: Config) !Request {
    var ctx = t.Context.allocInit(t.arena.allocator(), .{ .request = config });
    ctx.write(input);
    while (true) {
        const done = try ctx.conn.req_state.parse(ctx.stream);
        if (done) break;
    }
    return Request.init(ctx.conn.arena.allocator(), ctx.conn);
}

fn randomMethod(random: std.Random) []const u8 {
    return switch (random.uintAtMost(usize, 6)) {
        0 => "GET",
        1 => "PUT",
        2 => "POST",
        3 => "PATCH",
        4 => "DELETE",
        5 => "OPTIONS",
        6 => "HEAD",
        else => unreachable,
    };
}

fn buildRequest(header: []const []const u8, body: []const []const u8) []const u8 {
    var header_len: usize = 0;
    for (header) |h| {
        header_len += h.len;
    }

    var body_len: usize = 0;
    for (body) |b| {
        body_len += b.len;
    }

    var arr = std.ArrayList(u8).init(t.arena.allocator());
    // 100 for the Content-Length that we'll add and all the \r\n
    arr.ensureTotalCapacity(header_len + body_len + 100) catch unreachable;

    for (header) |h| {
        arr.appendSlice(h) catch unreachable;
        arr.appendSlice("\r\n") catch unreachable;
    }
    arr.appendSlice("Content-Length: ") catch unreachable;
    std.fmt.formatInt(body_len, 10, .lower, .{}, arr.writer()) catch unreachable;
    arr.appendSlice("\r\n\r\n") catch unreachable;

    for (body) |b| {
        arr.appendSlice(b) catch unreachable;
    }

    return arr.items;
}
