const std = @import("std");

const t = @import("test.zig");
const zerv = @import("zerv.zig");
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

test "response: write" {
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    {
        // no body
        var res = ctx.response();
        res.status = 401;
        try res.write();
        try ctx.expect("HTTP/1.1 401 \r\nContent-Length: 0\r\n\r\n");
    }

    {
        // body
        var res = ctx.response();
        res.status = 200;
        res.body = "hello";
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 5\r\n\r\nhello");
    }
}

test "response: content_type" {
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();
    res.content_type = zerv.ContentType.WEBP;
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Type: image/webp\r\nContent-Length: 0\r\n\r\n");
}
