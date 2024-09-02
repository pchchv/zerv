const std = @import("std");

pub const websocket = @import("websocket");

const t = @import("test.zig");
pub const zerv = @import("zerv.zog");
pub const middleware = @import("middleware/middleware.zig");

const Server = zerv.Server;
const Action = zerv.Action;
const Request = zerv.Request;
const Response = zerv.Response;
const Middleware = zerv.Middleware;
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
        router.all("/test/cors", TestDummyHandler.jsonRes, .{ .middlewares = cors });
        router.all("/test/middlewares", TestDummyHandler.middlewares, .{ .middlewares = middlewares });
        router.all("/test/dispatcher", TestDummyHandler.dispatchedAction, .{ .dispatcher = TestDummyHandler.routeSpecificDispacthcer });
        test_server_threads[0] = try default_server.listenInNewThread();
    }

    {
        dispatch_default_server = try Server(*TestHandlerDefaultDispatch).init(ga, .{ .port = 5993 }, &test_handler_default_dispatch1);
        var router = dispatch_default_server.router();
        router.get("/", TestHandlerDefaultDispatch.echo, .{});
        router.get("/write/*", TestHandlerDefaultDispatch.echoWrite, .{});
        router.get("/fail", TestHandlerDefaultDispatch.fail, .{});
        router.post("/login", TestHandlerDefaultDispatch.echo, .{});
        router.get("/test/body/cl", TestHandlerDefaultDispatch.clBody, .{});
        router.get("/test/headers", TestHandlerDefaultDispatch.headers, .{});
        router.all("/api/:version/users/:UserId", TestHandlerDefaultDispatch.params, .{});

        var admin_routes = router.group("/admin/", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch2, .handler = &test_handler_default_dispatch2 });
        admin_routes.get("/users", TestHandlerDefaultDispatch.echo);
        admin_routes.put("/users/:id", TestHandlerDefaultDispatch.echo);

        var debug_routes = router.group("/debug", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch3, .handler = &test_handler_default_dispatch3 });
        debug_routes.head("/ping", TestHandlerDefaultDispatch.echo);
        debug_routes.options("/stats", TestHandlerDefaultDispatch.echo);

        test_server_threads[1] = try dispatch_default_server.listenInNewThread();
    }

    {
        dispatch_server = try Server(*TestHandlerDispatch).init(ga, .{ .port = 5994 }, &test_handler_dispatch);
        var router = dispatch_server.router();
        router.get("/", TestHandlerDispatch.root, .{});
        test_server_threads[2] = try dispatch_server.listenInNewThread();
    }

    {
        dispatch_action_context_server = try Server(*TestHandlerDispatchContext).init(ga, .{ .port = 5995 }, &test_handler_disaptch_context);
        var router = dispatch_action_context_server.router();
        router.get("/", TestHandlerDispatchContext.root, .{});
        test_server_threads[3] = try dispatch_action_context_server.listenInNewThread();
    }

    {
        // with only 1 worker, and a min/max conn of 1,
        // each request should hit our reset path.
        reuse_server = try Server(void).init(ga, .{ .port = 5996, .workers = .{ .count = 1, .min_conn = 1, .max_conn = 1 } }, {});
        var router = reuse_server.router();
        router.get("/test/writer", TestDummyHandler.reuseWriter, .{});
        test_server_threads[4] = try reuse_server.listenInNewThread();
    }

    {
        handle_server = try Server(TestHandlerHandle).init(ga, .{ .port = 5997 }, TestHandlerHandle{});
        test_server_threads[5] = try handle_server.listenInNewThread();
    }

    {
        websocket_server = try Server(TestWebsocketHandler).init(ga, .{ .port = 5998 }, TestWebsocketHandler{});
        var router = websocket_server.router();
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
