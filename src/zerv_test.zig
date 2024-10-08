const std = @import("std");

pub const websocket = @import("websocket");

pub const t = @import("test.zig");
pub const zerv = @import("zerv.zog");
pub const testing = @import("testing.zig");
pub const middleware = @import("middleware/middleware.zig");

const Server = zerv.Server;
const Action = zerv.Action;
const Request = zerv.Request;
const Response = zerv.Response;
const Middleware = zerv.Middleware;
const ContentType = zerv.ContentType;
const MiddlewareConfig = zerv.MiddlewareConfig;

const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const TestUser = struct {
    id: []const u8,
    power: usize,
};

var global_test_allocator = std.heap.GeneralPurposeAllocator(.{}){};

var test_handler_dispatch = TestHandlerDispatch{ .state = 10 };
var test_handler_disaptch_context = TestHandlerDispatchContext{ .state = 20 };
var test_handler_default_dispatch1 = TestHandlerDefaultDispatch{ .state = 3 };
var test_handler_default_dispatch2 = TestHandlerDefaultDispatch{ .state = 99 };
var test_handler_default_dispatch3 = TestHandlerDefaultDispatch{ .state = 20 };

var reuse_server: Server(void) = undefined;
var default_server: Server(void) = undefined;
var handle_server: Server(TestHandlerHandle) = undefined;
var websocket_server: Server(TestWebsocketHandler) = undefined;
var dispatch_server: Server(*TestHandlerDispatch) = undefined;
var dispatch_default_server: Server(*TestHandlerDefaultDispatch) = undefined;
var dispatch_action_context_server: Server(*TestHandlerDispatchContext) = undefined;

var test_server_threads: [7]Thread = undefined;

const TestMiddleware = struct {
    const Config = struct {
        id: i32,
    };

    allocator: Allocator,
    v1: []const u8,
    v2: []const u8,

    fn init(config: TestMiddleware.Config, mc: MiddlewareConfig) !TestMiddleware {
        return .{
            .allocator = mc.allocator,
            .v1 = try std.fmt.allocPrint(mc.arena, "tm1-{d}", .{config.id}),
            .v2 = try std.fmt.allocPrint(mc.allocator, "tm2-{d}", .{config.id}),
        };
    }

    pub fn deinit(self: *const TestMiddleware) void {
        self.allocator.free(self.v2);
    }

    fn value1(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_1").?);
        return v[0..7];
    }

    fn value2(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_2").?);
        return v[0..7];
    }

    fn execute(self: *const TestMiddleware, req: *Request, _: *Response, executor: anytype) !void {
        try req.middlewares.put("text_middleware_1", (try req.arena.dupe(u8, self.v1)).ptr);
        try req.middlewares.put("text_middleware_2", (try req.arena.dupe(u8, self.v2)).ptr);
        return executor.next();
    }
};

// TestDummyHandler simulates having a void handler,
// but keeps the test actions organized within this namespace.
const TestDummyHandler = struct {
    const RouteData = struct {
        power: usize,
    };

    fn fail(_: *Request, _: *Response) !void {
        return error.Failure;
    }

    fn reqQuery(req: *Request, res: *Response) !void {
        res.status = 200;
        const query = try req.query();
        res.body = query.get("fav").?;
    }

    fn chunked(_: *Request, res: *Response) !void {
        res.header("Over", "9000!");
        res.status = 200;
        try res.chunk("Chunk 1");
        try res.chunk("and another chunk");
    }

    fn jsonRes(_: *Request, res: *Response) !void {
        res.status = 201;
        try res.json(.{ .over = 9000, .teg = "soup" }, .{});
    }

    fn routeData(req: *Request, res: *Response) !void {
        const rd: *const RouteData = @ptrCast(@alignCast(req.route_data.?));
        try res.json(.{ .power = rd.power }, .{});
    }

    fn eventStream(_: *Request, res: *Response) !void {
        res.status = 818;
        try res.startEventStream(StreamContext{ .data = "hello" }, StreamContext.handle);
    }

    const StreamContext = struct {
        data: []const u8,

        fn handle(self: StreamContext, stream: std.net.Stream) void {
            stream.writeAll(self.data) catch unreachable;
            stream.writeAll("a message") catch unreachable;
        }
    };

    fn routeSpecificDispacthcer(action: Action(void), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-1");
        return action(req, res);
    }

    fn dispatchedAction(_: *Request, res: *Response) !void {
        return res.directWriter().writeAll("action");
    }

    fn middlewares(req: *Request, res: *Response) !void {
        return res.json(.{
            .v1 = TestMiddleware.value1(req),
            .v2 = TestMiddleware.value2(req),
        }, .{});
    }

    // called by the re-use server,
    // but put here because,
    // like the default server this is a handler-less server
    fn reuseWriter(req: *Request, res: *Response) !void {
        res.status = 200;
        const query = try req.query();
        const count = try std.fmt.parseInt(u16, query.get("count").?, 10);

        var data = try res.arena.alloc(TestUser, count);
        for (0..count) |i| {
            data[i] = .{
                .id = try std.fmt.allocPrint(res.arena, "id-{d}", .{i}),
                .power = i,
            };
        }
        return res.json(.{ .data = data }, .{});
    }
};

const TestHandlerDefaultDispatch = struct {
    state: usize,

    fn dispatch2(h: *TestHandlerDefaultDispatch, action: Action(*TestHandlerDefaultDispatch), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-2");
        return action(h, req, res);
    }

    fn dispatch3(h: *TestHandlerDefaultDispatch, action: Action(*TestHandlerDefaultDispatch), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-3");
        return action(h, req, res);
    }

    fn echo(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        return res.json(.{
            .state = h.state,
            .method = @tagName(req.method),
            .path = req.url.path,
        }, .{});
    }

    fn echoWrite(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        var arr = std.ArrayList(u8).init(res.arena);
        try std.json.stringify(.{
            .state = h.state,
            .method = @tagName(req.method),
            .path = req.url.path,
        }, .{}, arr.writer());

        res.body = arr.items;
        return res.write();
    }

    fn params(_: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        const args = .{ req.param("version").?, req.param("UserId").? };
        res.body = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
    }

    fn headers(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        res.header("state", try std.fmt.allocPrint(res.arena, "{d}", .{h.state}));
        res.header("Echo", req.header("header-name").?);
        res.header("other", "test-value");
    }

    fn clBody(_: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        res.header("Echo-Body", req.body().?);
    }

    fn fail(_: *TestHandlerDefaultDispatch, _: *Request, _: *Response) !void {
        return error.TestUnhandledError;
    }

    pub fn notFound(h: *TestHandlerDefaultDispatch, _: *Request, res: *Response) !void {
        res.status = 404;
        res.header("state", try std.fmt.allocPrint(res.arena, "{d}", .{h.state}));
        res.body = "where lah?";
    }

    pub fn uncaughtError(h: *TestHandlerDefaultDispatch, _: *Request, res: *Response, err: anyerror) void {
        res.status = 500;
        res.header("state", std.fmt.allocPrint(res.arena, "{d}", .{h.state}) catch unreachable);
        res.header("err", @errorName(err));
        res.body = "#/why/arent/tags/hierarchical";
    }
};

const TestHandlerDispatch = struct {
    state: usize,

    pub fn dispatch(self: *TestHandlerDispatch, action: Action(*TestHandlerDispatch), req: *Request, res: *Response) !void {
        res.header("dstate", try std.fmt.allocPrint(res.arena, "{d}", .{self.state}));
        res.header("dispatch", "TestHandlerDispatch");
        return action(self, req, res);
    }

    fn root(h: *TestHandlerDispatch, _: *Request, res: *Response) !void {
        return res.json(.{ .state = h.state }, .{});
    }
};

const TestHandlerDispatchContext = struct {
    state: usize,

    const ActionContext = struct {
        other: usize,
    };

    pub fn dispatch(self: *TestHandlerDispatchContext, action: Action(*ActionContext), req: *Request, res: *Response) !void {
        res.header("dstate", try std.fmt.allocPrint(res.arena, "{d}", .{self.state}));
        res.header("dispatch", "TestHandlerDispatchContext");
        var action_context = ActionContext{ .other = self.state + 10 };
        return action(&action_context, req, res);
    }

    pub fn root(a: *const ActionContext, _: *Request, res: *Response) !void {
        return res.json(.{ .other = a.other }, .{});
    }
};

const TestHandlerHandle = struct {
    pub fn handle(_: TestHandlerHandle, req: *Request, res: *Response) void {
        const query = req.query() catch unreachable;
        std.fmt.format(res.writer(), "hello {s}", .{query.get("name") orelse "world"}) catch unreachable;
    }
};

const TestWebsocketHandler = struct {
    pub const WebsocketHandler = struct {
        ctx: u32,
        conn: *websocket.Conn,

        pub fn init(conn: *websocket.Conn, ctx: u32) !WebsocketHandler {
            return .{
                .ctx = ctx,
                .conn = conn,
            };
        }

        pub fn afterInit(self: *WebsocketHandler, ctx: u32) !void {
            try t.expectEqual(self.ctx, ctx);
        }

        pub fn clientMessage(self: *WebsocketHandler, data: []const u8) !void {
            if (std.mem.eql(u8, data, "close")) {
                self.conn.close(.{}) catch {};
                return;
            }
            try self.conn.write(data);
        }
    };

    pub fn upgrade(_: TestWebsocketHandler, req: *Request, res: *Response) !void {
        if (try zerv.upgradeWebsocket(WebsocketHandler, req, res, 9001) == false) {
            res.status = 500;
            res.body = "invalid websocket";
        }
    }
};

fn testStream(port: u16) std.net.Stream {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = 0,
        .usec = 20_000,
    });

    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    const stream = std.net.tcpConnectToAddress(address) catch unreachable;
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch unreachable;
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch unreachable;
    return stream;
}

fn testReadAll(stream: std.net.Stream, buf: []u8) []u8 {
    var pos: usize = 0;
    var blocked = false;
    while (true) {
        std.debug.assert(pos < buf.len);
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (blocked) return buf[0..pos];
                blocked = true;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => @panic(@errorName(err)),
        };

        if (n == 0) {
            return buf[0..pos];
        }

        pos += n;
        blocked = false;
    }
    unreachable;
}

fn testReadParsed(stream: std.net.Stream) testing.Testing.Response {
    var buf: [4096]u8 = undefined;
    const data = testReadAll(stream, &buf);
    return testing.parse(data) catch unreachable;
}

fn testReadHeader(stream: std.net.Stream) testing.Testing.Response {
    var pos: usize = 0;
    var blocked = false;
    var buf: [1024]u8 = undefined;
    while (true) {
        std.debug.assert(pos < buf.len);
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (blocked) unreachable;
                blocked = true;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => @panic(@errorName(err)),
        };

        if (n == 0) unreachable;

        pos += n;
        if (std.mem.endsWith(u8, buf[0..pos], "\r\n\r\n")) {
            return testing.parse(buf[0..pos]) catch unreachable;
        }
        blocked = false;
    }
    unreachable;
}

test "tests:beforeAll" {
    // this will leak since the server will run until the process exits.
    // If using testing allocator, it'll report the leak.
    const ga = global_test_allocator.allocator();

    {
        default_server = try Server(void).init(ga, .{ .port = 5992 }, {});

        // only need to do this because we're using listenInNewThread instead of blocking here.
        // So the array to hold the middleware needs to outlive this function.
        var cors = try default_server.arena.alloc(Middleware(void), 1);
        cors[0] = try default_server.middleware(middleware.Cors, .{
            .max_age = "300",
            .methods = "GET,POST",
            .origin = "zerv.local",
            .headers = "content-type",
        });

        var middlewares = try default_server.arena.alloc(Middleware(void), 2);
        middlewares[0] = try default_server.middleware(TestMiddleware, .{ .id = 100 });
        middlewares[1] = cors[0];

        var router = default_server.router();
        router.get("/fail", TestDummyHandler.fail, .{});
        router.get("/test/json", TestDummyHandler.jsonRes, .{});
        router.get("/test/query", TestDummyHandler.reqQuery, .{});
        router.get("/test/stream", TestDummyHandler.eventStream, .{});
        router.get("/test/chunked", TestDummyHandler.chunked, .{});
        router.get("/test/route_data", TestDummyHandler.routeData, .{ .data = &TestDummyHandler.RouteData{ .power = 12345 } });
        router.all("/test/cors", TestDummyHandler.jsonRes, .{ .middlewares = cors });
        router.all("/test/middlewares", TestDummyHandler.middlewares, .{ .middlewares = middlewares });
        router.all("/test/dispatcher", TestDummyHandler.dispatchedAction, .{ .dispatcher = TestDummyHandler.routeSpecificDispacthcer });
        test_server_threads[0] = try default_server.listenInNewThread();
    }

    {
        dispatch_default_server = try Server(*TestHandlerDefaultDispatch).init(ga, .{ .port = 5993 }, &test_handler_default_dispatch1);
        var router = dispatch_default_server.router(.{});
        router.get("/", TestHandlerDefaultDispatch.echo, .{});
        router.get("/write/*", TestHandlerDefaultDispatch.echoWrite, .{});
        router.get("/fail", TestHandlerDefaultDispatch.fail, .{});
        router.post("/login", TestHandlerDefaultDispatch.echo, .{});
        router.get("/test/body/cl", TestHandlerDefaultDispatch.clBody, .{});
        router.get("/test/headers", TestHandlerDefaultDispatch.headers, .{});
        router.all("/api/:version/users/:UserId", TestHandlerDefaultDispatch.params, .{});

        var admin_routes = router.group("/admin/", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch2, .handler = &test_handler_default_dispatch2 });
        admin_routes.get("/users", TestHandlerDefaultDispatch.echo, .{});
        admin_routes.put("/users/:id", TestHandlerDefaultDispatch.echo, .{});

        var debug_routes = router.group("/debug", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch3, .handler = &test_handler_default_dispatch3 });
        debug_routes.head("/ping", TestHandlerDefaultDispatch.echo, .{});
        debug_routes.options("/stats", TestHandlerDefaultDispatch.echo, .{});

        test_server_threads[1] = try dispatch_default_server.listenInNewThread();
    }

    {
        dispatch_server = try Server(*TestHandlerDispatch).init(ga, .{ .port = 5994 }, &test_handler_dispatch);
        var router = dispatch_server.router(.{});
        router.get("/", TestHandlerDispatch.root, .{});
        test_server_threads[2] = try dispatch_server.listenInNewThread();
    }

    {
        dispatch_action_context_server = try Server(*TestHandlerDispatchContext).init(ga, .{ .port = 5995 }, &test_handler_disaptch_context);
        var router = dispatch_action_context_server.router(.{});
        router.get("/", TestHandlerDispatchContext.root, .{});
        test_server_threads[3] = try dispatch_action_context_server.listenInNewThread();
    }

    {
        // with only 1 worker, and a min/max conn of 1,
        // each request should hit our reset path.
        reuse_server = try Server(void).init(ga, .{ .port = 5996, .workers = .{ .count = 1, .min_conn = 1, .max_conn = 1 } }, {});
        var router = reuse_server.router(.{});
        router.get("/test/writer", TestDummyHandler.reuseWriter, .{});
        test_server_threads[4] = try reuse_server.listenInNewThread();
    }

    {
        handle_server = try Server(TestHandlerHandle).init(ga, .{ .port = 5997 }, TestHandlerHandle{});
        test_server_threads[5] = try handle_server.listenInNewThread();
    }

    {
        websocket_server = try Server(TestWebsocketHandler).init(ga, .{ .port = 5998 }, TestWebsocketHandler{});
        var router = websocket_server.router(.{});
        router.get("/ws", TestWebsocketHandler.upgrade, .{});
        test_server_threads[6] = try websocket_server.listenInNewThread();
    }

    std.testing.refAllDecls(@This());
}

test "tests:afterAll" {
    default_server.stop();
    dispatch_default_server.stop();
    dispatch_server.stop();
    dispatch_action_context_server.stop();
    reuse_server.stop();
    handle_server.stop();
    websocket_server.stop();

    for (test_server_threads) |thread| {
        thread.join();
    }

    default_server.deinit();
    dispatch_default_server.deinit();
    dispatch_server.deinit();
    dispatch_action_context_server.deinit();
    reuse_server.deinit();
    handle_server.deinit();
    websocket_server.deinit();

    try t.expectEqual(false, global_test_allocator.detectLeaks());
}

test "zerv: quick shutdown" {
    var server = try Server(void).init(t.allocator, .{ .port = 6992 }, {});
    const thrd = try server.listenInNewThread();
    server.stop();
    thrd.join();
    server.deinit();
}

test "zerv: invalid request" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA / HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: invalid request path" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA /hello\rn\nWorld:test HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: invalid header name" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nOver: 9000\r\nHel\tlo:World\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: invalid content length value (1)" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: HaHA\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: invalid content length value (2)" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 1.0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: overflow content length" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 999999999999999999999999999\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "zerv: no route" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 404 \r\nContent-Length: 9\r\n\r\nNot Found", testReadAll(stream, &buf));
}

test "zerv: no route with custom notFound handler" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /not_found HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 404 \r\nstate: 3\r\nContent-Length: 10\r\n\r\nwhere lah?", testReadAll(stream, &buf));
}

test "zerv: unhandled exception" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [150]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nContent-Length: 21\r\n\r\nInternal Server Error", testReadAll(stream, &buf));
}

test "zerv: unhandled exception with custom error handler" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [150]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nstate: 3\r\nerr: TestUnhandledError\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", testReadAll(stream, &buf));
}

test "zerv: route params" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", testReadAll(stream, &buf));
}

test "zerv: router groups" {
    const stream = testStream(5993);
    defer stream.close();

    {
        try stream.writeAll("GET / HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 3, .method = "GET", .path = "/" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }

    {
        try stream.writeAll("GET /admin/users HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 99, .method = "GET", .path = "/admin/users" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("PUT /admin/users/:id HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 99, .method = "PUT", .path = "/admin/users/:id" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("HEAD /debug/ping HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 20, .method = "HEAD", .path = "/debug/ping" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("OPTIONS /debug/stats HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 20, .method = "OPTIONS", .path = "/debug/stats" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("POST /login HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 3, .method = "POST", .path = "/login" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }
}

test "zerv: request and response headers" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nstate: 3\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "zerv: content-length body" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "zerv: route-specific dispatcher" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("HEAD /test/dispatcher HTTP/1.1\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\ndispatcher: test-dispatcher-1\r\nContent-Length: 6\r\n\r\naction", testReadAll(stream, &buf));
}

test "zerv: custom dispatch without action context" {
    const stream = testStream(5994);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Type: application/json\r\ndstate: 10\r\ndispatch: TestHandlerDispatch\r\nContent-Length: 12\r\n\r\n{\"state\":10}", testReadAll(stream, &buf));
}

test "zerv: custom dispatch with action context" {
    const stream = testStream(5995);
    defer stream.close();
    try stream.writeAll("GET /?name=teg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Type: application/json\r\ndstate: 20\r\ndispatch: TestHandlerDispatchContext\r\nContent-Length: 12\r\n\r\n{\"other\":30}", testReadAll(stream, &buf));
}

test "zerv: CORS" {
    const stream = testStream(5992);
    defer stream.close();

    {
        try stream.writeAll("GET /echo HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Origin"));
    }

    {
        // cors endpoint but not cors options
        try stream.writeAll("OPTIONS /test/cors HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectString("zerv.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // cors request
        try stream.writeAll("OPTIONS /test/cors HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectString("300", res.headers.get("Access-Control-Max-Age").?);
        try t.expectString("GET,POST", res.headers.get("Access-Control-Allow-Methods").?);
        try t.expectString("content-type", res.headers.get("Access-Control-Allow-Headers").?);
        try t.expectString("zerv.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // cors request, non-options
        try stream.writeAll("GET /test/cors HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectString("zerv.local", res.headers.get("Access-Control-Allow-Origin").?);
    }
}

test "zerv: json response" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 201 \r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", testReadAll(stream, &buf));
}

test "zerv: query" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 11\r\n\r\nkeemun tea!", testReadAll(stream, &buf));
}

test "zerv: chunked" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/chunked HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nOver: 9000!\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nChunk 1\r\n11\r\nand another chunk\r\n0\r\n\r\n", testReadAll(stream, &buf));
}

test "zerv: middlewares" {
    const stream = testStream(5992);
    defer stream.close();

    {
        try stream.writeAll("GET /test/middlewares HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .v1 = "tm1-100", .v2 = "tm2-100" });
        try t.expectString("zerv.local", res.headers.get("Access-Control-Allow-Origin").?);
    }
}

test "zerv: keepalive" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", testReadAll(stream, &buf));

    try stream.writeAll("GET /api/v2/users/123 HTTP/1.1\r\n\r\n");
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 19\r\n\r\nversion=v2,user=123", testReadAll(stream, &buf));
}

test "zerv: keepalive with explicit write" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /write/9001 HTTP/1.1\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 47\r\n\r\n{\"state\":3,\"method\":\"GET\",\"path\":\"/write/9001\"}", testReadAll(stream, &buf));

    try stream.writeAll("GET /write/123 HTTP/1.1\r\n\r\n");
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 46\r\n\r\n{\"state\":3,\"method\":\"GET\",\"path\":\"/write/123\"}", testReadAll(stream, &buf));
}

test "zerv: event stream" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/stream HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();

    try t.expectEqual(818, res.status);
    try t.expectEqual(true, res.headers.get("Content-Length") == null);
    try t.expectString("text/event-stream", res.headers.get("Content-Type").?);
    try t.expectString("no-cache", res.headers.get("Cache-Control").?);
    try t.expectString("keep-alive", res.headers.get("Connection").?);
    try t.expectString("helloa message", res.body);
}

test "zerv: custom handle" {
    const stream = testStream(5997);
    defer stream.close();
    try stream.writeAll("GET /whatever?name=teg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 9\r\n\r\nhello teg", testReadAll(stream, &buf));
}

test "zerv: writer re-use" {
    defer t.reset();

    const stream = testStream(5996);
    defer stream.close();

    var expected: [10]TestUser = undefined;

    var buf: [100]u8 = undefined;
    for (0..10) |i| {
        expected[i] = .{
            .id = try std.fmt.allocPrint(t.arena.allocator(), "id-{d}", .{i}),
            .power = i,
        };
        try stream.writeAll(try std.fmt.bufPrint(&buf, "GET /test/writer?count={d} HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .{i + 1}));

        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .data = expected[0 .. i + 1] });
    }
}

test "zerv: request in chunks" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/use");
    std.time.sleep(std.time.ns_per_ms * 10);
    try stream.writeAll("rs/11 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 18\r\n\r\nversion=v2,user=11", testReadAll(stream, &buf));
}

test "zerv: route data" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/route_data HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();
    try res.expectJson(.{ .power = 12345 });
}

test "ContentType: forX" {
    inline for (@typeInfo(ContentType).@"enum".fields) |field| {
        if (comptime std.mem.eql(u8, "BINARY", field.name)) continue;
        if (comptime std.mem.eql(u8, "EVENTS", field.name)) continue;
        try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension(field.name));
        try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension("." ++ field.name));
        try t.expectEqual(@field(ContentType, field.name), ContentType.forFile("some_file." ++ field.name));
    }
    // variations
    try t.expectEqual(ContentType.HTML, ContentType.forExtension(".htm"));
    try t.expectEqual(ContentType.JPG, ContentType.forExtension(".jpeg"));

    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".spice"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(""));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".x"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile(""));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("must.spice"));
}

test "websocket: invalid request" {
    const stream = testStream(5998);
    defer stream.close();
    try stream.writeAll("GET /ws HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();
    try t.expectString("invalid websocket", res.body);
}

test "websocket: upgrade" {
    const stream = testStream(5998);
    defer stream.close();

    try stream.writeAll("GET /ws HTTP/1.1\r\nContent-Length: 0\r\n");
    try stream.writeAll("upgrade: WEBsocket\r\n");
    try stream.writeAll("Sec-Websocket-verSIon: 13\r\n");
    try stream.writeAll("ConnectioN: abc,upgrade,123\r\n");
    try stream.writeAll("SEC-WEBSOCKET-KeY: a-secret-key\r\n\r\n");

    var res = testReadHeader(stream);
    defer res.deinit();

    try t.expectEqual(101, res.status);
    try t.expectString("websocket", res.headers.get("Upgrade").?);
    try t.expectString("upgrade", res.headers.get("Connection").?);
    try t.expectString("55eM2SNGu+68v5XXrr982mhPFkU=", res.headers.get("Sec-Websocket-Accept").?);

    try stream.writeAll(&websocket.frameText("over 9000!"));
    try stream.writeAll(&websocket.frameText("close"));

    var pos: usize = 0;
    var wait_count: usize = 0;
    var buf: [100]u8 = undefined;
    while (pos < 16) {
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (wait_count == 100) {
                    break;
                }
                wait_count += 1;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) {
            break;
        }
        pos += n;
    }

    try t.expectEqual(16, pos);
    try t.expectEqual(129, buf[0]);
    try t.expectEqual(10, buf[1]);
    try t.expectString("over 9000!", buf[2..12]);
    try t.expectString(&.{ 136, 2, 3, 232 }, buf[12..16]);
}
