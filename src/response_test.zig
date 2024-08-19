const std = @import("std");

const t = @import("test.zig");
const r = @import("response.zig");

test "writeInt" {
    var buf: [10]u8 = undefined;
    var tst: [10]u8 = undefined;
    for (0..100_009) |i| {
        const expected_len = std.fmt.formatIntBuf(tst[0..], i, 10, .lower, .{});
        const l = r.writeInt(&buf, @intCast(i));
        try t.expectString(tst[0..expected_len], buf[0..l]);
    }
}
