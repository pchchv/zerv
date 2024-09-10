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
