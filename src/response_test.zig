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

test "response: write header_buffer_size" {
    {
        // no header or bodys
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 792;
        try res.write();
        try ctx.expect("HTTP/1.1 792 \r\nContent-Length: 0\r\n\r\n");
    }

    {
        // no body
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 401;
        res.header("a-header", "a-value");
        res.header("b-hdr", "b-val");
        res.header("c-header11", "cv");
        try res.write();
        try ctx.expect("HTTP/1.1 401 \r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 0\r\n\r\n");
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 8;
        res.header("a-header", "a-value");
        res.header("b-hdr", "b-val");
        res.header("c-header11", "cv");
        res.body = "hello world!";
        try res.write();
        try ctx.expect("HTTP/1.1 8 \r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 12\r\n\r\nhello world!");
    }
}

test "response: header" {
    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.header("Key1", "Value1");
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nKey1: Value1\r\nContent-Length: 0\r\n\r\n");
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        const k = try t.allocator.dupe(u8, "Key2");
        const v = try t.allocator.dupe(u8, "Value2");
        try res.headerOpts(k, v, .{ .dupe_name = true, .dupe_value = true });
        t.allocator.free(k);
        t.allocator.free(v);
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nKey2: Value2\r\nContent-Length: 0\r\n\r\n");
    }
}

test "response: direct writer" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();

    var writer = res.directWriter();
    writer.truncate(1);
    try writer.writeByte('[');
    writer.truncate(4);
    try writer.writeByte('[');
    try writer.writeAll("12345");
    writer.truncate(2);
    try writer.writeByte(',');
    try writer.writeAll("456");
    try writer.writeByte(',');
    writer.truncate(1);
    try writer.writeByte(']');

    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 9\r\n\r\n[123,456]");
}

// this used to crash
test "response: multiple writers" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();
    var res = ctx.response();
    {
        var w = res.writer();
        try w.writeAll("a" ** 5000);
    }
    {
        var w = res.writer();
        try w.writeAll("z" ** 10);
    }
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 5010\r\n\r\n" ++ ("a" ** 5000) ++ ("z" ** 10));
}

test "response: clearWriter" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();
    var writer = res.writer();

    try writer.writeAll("abc");
    res.clearWriter();
    try writer.writeAll("123");

    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 3\r\n\r\n123");
}
