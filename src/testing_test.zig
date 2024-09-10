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
