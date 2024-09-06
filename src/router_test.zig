const t = @import("test.zig");
const zerv = @import("zerv.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");

const Params = @import("params.zig").Params;
const Router = @import("router.zig").Router;

const FakeMiddlewareImpl = struct {
    id: u32,
};

test "route: root" {
    defer t.reset();

    var params = try Params.init(t.arena.allocator(), 5);
    var router = Router(void, zerv.Action(void)).init(t.arena.allocator(), testDispatcher1, {}) catch unreachable;
    router.get("/", testRoute1, .{});
    router.put("/", testRoute2, .{});
    router.post("", testRoute3, .{});
    router.all("/all", testRoute4, .{});

    const urls = .{ "/", "/other", "/all" };
    try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, "", &params).?.action);
    try t.expectEqual(&testRoute2, router.route(zerv.Method.PUT, "", &params).?.action);
    try t.expectEqual(&testRoute3, router.route(zerv.Method.POST, "", &params).?.action);

    try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, urls[0], &params).?.action);
    try t.expectEqual(&testRoute2, router.route(zerv.Method.PUT, urls[0], &params).?.action);
    try t.expectEqual(&testRoute3, router.route(zerv.Method.POST, urls[0], &params).?.action);

    try t.expectEqual(null, router.route(zerv.Method.GET, urls[1], &params));
    try t.expectEqual(null, router.route(zerv.Method.DELETE, urls[0], &params));

    // test "all" route
    inline for (@typeInfo(zerv.Method).@"enum".fields) |field| {
        const m = @as(zerv.Method, @enumFromInt(field.value));
        try t.expectEqual(&testRoute4, router.route(m, urls[2], &params).?.action);
    }
}

test "route: static" {
    defer t.reset();

    var params = try Params.init(t.arena.allocator(), 5);
    var router = Router(void, zerv.Action(void)).init(t.arena.allocator(), testDispatcher1, {}) catch unreachable;

    router.get("hello/world", testRoute1, .{});
    router.get("/over/9000/", testRoute2, .{});

    {
        const urls = .{ "hello/world", "/hello/world", "hello/world/", "/hello/world/" };
        // all trailing/leading slash combinations
        try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, urls[0], &params).?.action);
        try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, urls[1], &params).?.action);
        try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, urls[2], &params).?.action);
    }

    {
        const urls = .{ "over/9000", "/over/9000", "over/9000/", "/over/9000/" };
        // all trailing/leading slash combinations
        inline for (urls) |url| {
            try t.expectEqual(&testRoute2, router.route(zerv.Method.GET, url, &params).?.action);

            // different method
            try t.expectEqual(null, router.route(zerv.Method.PUT, url, &params));
        }
    }

    {
        // random not found
        const urls = .{ "over/9000!", "over/ 9000" };
        inline for (urls) |url| {
            try t.expectEqual(null, router.route(zerv.Method.GET, url, &params));
        }
    }
}

test "route: params" {
    defer t.reset();

    var params = try Params.init(t.arena.allocator(), 5);
    var router = Router(void, zerv.Action(void)).init(t.arena.allocator(), testDispatcher1, {}) catch unreachable;

    router.get("/:p1", testRoute1, .{});
    router.get("/users/:p2", testRoute2, .{});
    router.get("/users/:p2/fav", testRoute3, .{});
    router.get("/users/:p2/like", testRoute4, .{});
    router.get("/users/:p2/fav/:p3", testRoute5, .{});
    router.get("/users/:p2/like/:p3", testRoute6, .{});

    {
        // root param
        try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, "info", &params).?.action);
        try t.expectEqual(1, params.len);
        try t.expectString("info", params.get("p1").?);
    }

    {
        // nested param
        params.reset();
        try t.expectEqual(&testRoute2, router.route(zerv.Method.GET, "/users/33", &params).?.action);
        try t.expectEqual(1, params.len);
        try t.expectString("33", params.get("p2").?);
    }

    {
        // nested param with statix suffix
        params.reset();
        try t.expectEqual(&testRoute3, router.route(zerv.Method.GET, "/users/9/fav", &params).?.action);
        try t.expectEqual(1, params.len);
        try t.expectString("9", params.get("p2").?);

        params.reset();
        try t.expectEqual(&testRoute4, router.route(zerv.Method.GET, "/users/9/like", &params).?.action);
        try t.expectEqual(1, params.len);
        try t.expectString("9", params.get("p2").?);
    }

    {
        // nested params
        params.reset();
        try t.expectEqual(&testRoute5, router.route(zerv.Method.GET, "/users/u1/fav/blue", &params).?.action);
        try t.expectEqual(2, params.len);
        try t.expectString("u1", params.get("p2").?);
        try t.expectString("blue", params.get("p3").?);

        params.reset();
        try t.expectEqual(&testRoute6, router.route(zerv.Method.GET, "/users/u3/like/tea", &params).?.action);
        try t.expectEqual(2, params.len);
        try t.expectString("u3", params.get("p2").?);
        try t.expectString("tea", params.get("p3").?);
    }

    {
        // not_found
        params.reset();
        try t.expectEqual(null, router.route(zerv.Method.GET, "/users/u1/other", &params));
        try t.expectEqual(0, params.len);

        try t.expectEqual(null, router.route(zerv.Method.GET, "/users/u1/favss/blue", &params));
        try t.expectEqual(0, params.len);
    }
}

test "route: glob" {
    defer t.reset();

    var params = try Params.init(t.arena.allocator(), 5);
    var router = Router(void, zerv.Action(void)).init(t.arena.allocator(), testDispatcher1, {}) catch unreachable;

    router.get("/*", testRoute1, .{});
    router.get("/users/*", testRoute2, .{});
    router.get("/users/*/test", testRoute3, .{});
    router.get("/users/other/test", testRoute4, .{});

    {
        // root glob
        const urls = .{ "/anything", "/this/could/be/anything", "/" };
        inline for (urls) |url| {
            try t.expectEqual(&testRoute1, router.route(zerv.Method.GET, url, &params).?.action);
            try t.expectEqual(0, params.len);
        }
    }

    {
        // nest glob
        const urls = .{ "/users/", "/users", "/users/hello", "/users/could/be/anything" };
        inline for (urls) |url| {
            try t.expectEqual(&testRoute2, router.route(zerv.Method.GET, url, &params).?.action);
            try t.expectEqual(0, params.len);
        }
    }

    {
        // nest glob specific
        const urls = .{ "/users/hello/test", "/users/x/test" };
        inline for (urls) |url| {
            try t.expectEqual(&testRoute3, router.route(zerv.Method.GET, url, &params).?.action);
            try t.expectEqual(0, params.len);
        }
    }

    {
        // nest glob specific
        try t.expectEqual(&testRoute4, router.route(zerv.Method.GET, "/users/other/test", &params).?.action);
        try t.expectEqual(0, params.len);
    }
}

fn fakeMiddleware(impl: *const FakeMiddlewareImpl) zerv.Middleware(void) {
    return .{
        .ptr = @constCast(impl),
        .deinitFn = undefined,
        .executeFn = undefined,
    };
}

fn testDispatcher1(_: zerv.Action(void), _: *Request, _: *Response) anyerror!void {}
fn testRoute1(_: *Request, _: *Response) anyerror!void {}
fn testRoute2(_: *Request, _: *Response) anyerror!void {}
fn testRoute3(_: *Request, _: *Response) anyerror!void {}
fn testRoute4(_: *Request, _: *Response) anyerror!void {}
fn testRoute5(_: *Request, _: *Response) anyerror!void {}
fn testRoute6(_: *Request, _: *Response) anyerror!void {}
