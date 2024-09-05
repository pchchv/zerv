const std = @import("std");

const t = @import("test.zig");
const r = @import("request.zeg");

const atoi = r.atoi;

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
