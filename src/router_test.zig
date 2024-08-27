const t = @import("test.zig");
const r = @import("router.zig");
const zerv = @import("zerv.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");

const Params = @import("params.zig").Params;

const Router = r.Router;

test "route: root" {
    var params = try Params.init(t.allocator, 5);
    defer params.deinit(t.allocator);

    var router = Router(void, zerv.Action(void)).init(t.allocator, testDispatcher1, {}) catch unreachable;
    defer router.deinit(t.allocator);
    router.get("/", testRoute1);
    router.put("/", testRoute2);
    router.post("", testRoute3);
    router.all("/all", testRoute4);

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
    inline for (@typeInfo(zerv.Method).Enum.fields) |field| {
        const m = @as(zerv.Method, @enumFromInt(field.value));
        try t.expectEqual(&testRoute4, router.route(m, urls[2], &params).?.action);
    }
}

test "route: static" {
    var params = try Params.init(t.allocator, 5);
    defer params.deinit(t.allocator);

    var router = Router(void, zerv.Action(void)).init(t.allocator, testDispatcher1, {}) catch unreachable;
    defer router.deinit(t.allocator);
    router.get("hello/world", testRoute1);
    router.get("/over/9000/", testRoute2);

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

fn testDispatcher1(_: zerv.Action(void), _: *Request, _: *Response) anyerror!void {}
fn testRoute1(_: *Request, _: *Response) anyerror!void {}
fn testRoute2(_: *Request, _: *Response) anyerror!void {}
fn testRoute3(_: *Request, _: *Response) anyerror!void {}
fn testRoute4(_: *Request, _: *Response) anyerror!void {}
fn testRoute5(_: *Request, _: *Response) anyerror!void {}
fn testRoute6(_: *Request, _: *Response) anyerror!void {}
