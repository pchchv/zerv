const t = @import("test.zig");
const w = @import("worker.zig");

const BufferPool = @import("buffer.zig").Pool;

const TestNode = struct {
    id: i32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: w.List(TestNode)) !void {
    if (expected.len == 0) {
        try t.expectEqual(null, list.head);
        try t.expectEqual(null, list.tail);
        return;
    }

    var i: usize = 0;
    var next = list.head;
    while (next) |node| {
        try t.expectEqual(expected[i], node.id);
        i += 1;
        next = node.next;
    }
    try t.expectEqual(expected.len, i);

    i = expected.len;
    var prev = list.tail;
    while (prev) |node| {
        i -= 1;
        try t.expectEqual(expected[i], node.id);
        prev = node.prev;
    }
    try t.expectEqual(0, i);
}

test "HTTPConnPool" {
    var bp = try BufferPool.init(t.allocator, 2, 64);
    defer bp.deinit();

    var p = try w.HTTPConnPool.init(t.allocator, &bp, undefined, &.{
        .workers = .{ .min_conn = 2 },
        .request = .{ .buffer_size = 64 },
    });
    defer p.deinit();

    const s1 = try p.acquire();
    const s2 = try p.acquire();
    const s3 = try p.acquire();

    try t.expectEqual(true, s1.req_state.buf.ptr != s2.req_state.buf.ptr);
    try t.expectEqual(true, s1.req_state.buf.ptr != s3.req_state.buf.ptr);
    try t.expectEqual(true, s2.req_state.buf.ptr != s3.req_state.buf.ptr);

    p.release(s2);
    const s4 = try p.acquire();
    try t.expectEqual(true, s4.req_state.buf.ptr == s2.req_state.buf.ptr);

    p.release(s1);
    p.release(s3);
    p.release(s4);
}
