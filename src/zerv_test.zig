const std = @import("std");

pub const websocket = @import("websocket");

const t = @import("test.zig");
pub const zerv = @import("zerv.zog");

const Action = zerv.Action;
const Request = zerv.Request;
const Response = zerv.Response;
const MiddlewareConfig = zerv.MiddlewareConfig;

const Allocator = std.mem.Allocator;

const TestUser = struct {
    id: []const u8,
    power: usize,
};

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
