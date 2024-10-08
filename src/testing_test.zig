const t = @import("test.zig");
const testing = @import("testing.zig");

const init = testing.init;

test "testing: params" {
    var ht = init(.{});
    defer ht.deinit();

    ht.param("id", "over9000");
    try t.expectString("over9000", ht.req.params.get("id").?);
    try t.expectEqual(null, ht.req.params.get("other"));
}

test "testing: header" {
    var ht = init(.{});
    defer ht.deinit();

    ht.header("Search", "tea");
    ht.header("Category", "447");

    try t.expectString("tea", ht.req.headers.get("search").?);
    try t.expectString("447", ht.req.headers.get("category").?);
    try t.expectEqual(null, ht.req.headers.get("other"));
}

test "testing: body" {
    var ht = init(.{});
    defer ht.deinit();

    ht.body("the body");
    try t.expectString("the body", ht.req.body().?);
}

test "testing: expectBody empty" {
    var ht = init(.{});
    defer ht.deinit();
    try ht.expectStatus(200);
    try ht.expectBody("");
    try ht.expectHeaderCount(1);
    try ht.expectHeader("Content-Length", "0");
}

test "testing: expectBody" {
    var ht = init(.{});
    defer ht.deinit();
    ht.res.status = 404;
    ht.res.body = "nope";

    try ht.expectStatus(404);
    try ht.expectBody("nope");
}

test "testing: query" {
    var ht = init(.{});
    defer ht.deinit();

    ht.query("search", "t:ea");
    ht.query("category", "447");

    const query = try ht.req.query();
    try t.expectString("t:ea", query.get("search").?);
    try t.expectString("447", query.get("category").?);
    try t.expectString("search=t%3Aea&category=447", ht.req.url.query);
    try t.expectEqual(null, query.get("other"));
}

test "testing: empty query" {
    var ht = init(.{});
    defer ht.deinit();

    const query = try ht.req.query();
    try t.expectEqual(0, query.len);
}

test "testing: query via url" {
    var ht = init(.{});
    defer ht.deinit();
    ht.url("/hello?duncan=idaho");

    const query = try ht.req.query();
    try t.expectString("idaho", query.get("duncan").?);
}

test "testing: json" {
    var ht = init(.{});
    defer ht.deinit();

    ht.json(.{ .over = 9000 });
    try t.expectString("{\"over\":9000}", ht.req.body().?);
}

test "testing: expectJson" {
    var ht = init(.{});
    defer ht.deinit();
    ht.res.status = 201;
    try ht.res.json(.{ .tea = "keemun", .price = .{ .amount = 4990, .discount = 0.1 } }, .{});

    try ht.expectStatus(201);
    try ht.expectJson(.{ .price = .{ .discount = 0.1, .amount = 4990 }, .tea = "keemun" });
}

test "testing: getJson" {
    var ht = init(.{});
    defer ht.deinit();

    ht.res.status = 201;
    try ht.res.json(.{ .tea = "silver needle" }, .{});

    try ht.expectStatus(201);
    const json = try ht.getJson();
    try t.expectString("silver needle", json.object.get("tea").?.string);
}

test "testing: form" {
    var ht = init(.{ .request = .{ .max_form_count = 2 } });
    defer ht.deinit();

    ht.form(.{ .over = "(9000)", .hello = "wo rld" });
    const fd = try ht.req.formData();
    try t.expectString("(9000)", fd.get("over").?);
    try t.expectString("wo rld", fd.get("hello").?);
}

test "testing: parseResponse" {
    var ht = init(.{});
    defer ht.deinit();
    ht.res.status = 201;
    try ht.res.json(.{ .tea = 33 }, .{});

    try ht.expectStatus(201);
    const res = try ht.parseResponse();
    try t.expectEqual(201, res.status);
    try t.expectEqual(2, res.headers.count());
}
