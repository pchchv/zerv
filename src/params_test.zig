const t = @import("test.zig");
const Params = @import("params.zig").Params;

test "params: get" {
    const allocator = t.allocator;
    var params = try Params.init(allocator, 10);
    var names = [_][]const u8{ "over", "duncan" };
    params.addValue("9000");
    params.addValue("idaho");
    params.addNames(names[0..]);

    try t.expectEqual("9000", params.get("over").?);
    try t.expectEqual("idaho", params.get("duncan").?);

    params.reset();
    try t.expectEqual(null, params.get("over"));
    try t.expectEqual(null, params.get("duncan"));

    params.addValue("!9000!");
    params.addNames(names[0..1]);
    try t.expectEqual("!9000!", params.get("over").?);

    params.deinit(t.allocator);
}
