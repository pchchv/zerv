const t = @import("test.zig");
const Pool = @import("buffer.zig").Pool;

test "BufferPool" {
    var pool = try Pool.init(t.allocator, 2, 10);
    defer pool.deinit();

    {
        // bigger than our buffers in pool
        const buffer = try pool.alloc(11);
        defer pool.release(buffer);
        try t.expectEqual(.dynamic, buffer.type);
        try t.expectEqual(11, buffer.data.len);
    }

    {
        // smaller than our buffers in pool
        const buf1 = try pool.alloc(4);
        try t.expectEqual(.pooled, buf1.type);
        try t.expectEqual(10, buf1.data.len);

        const buf2 = try pool.alloc(5);
        try t.expectEqual(.pooled, buf2.type);
        try t.expectEqual(10, buf2.data.len);

        try t.expectEqual(false, &buf1.data[0] == &buf2.data[0]);

        // no more buffers in the pool, creates a dynamic buffer
        const buf3 = try pool.alloc(6);
        try t.expectEqual(.dynamic, buf3.type);
        try t.expectEqual(6, buf3.data.len);

        pool.release(buf1);

        // now has items!
        const buf4 = try pool.alloc(6);
        try t.expectEqual(.pooled, buf4.type);
        try t.expectEqual(10, buf4.data.len);

        pool.release(buf2);
        pool.release(buf3);
        pool.release(buf4);
    }
}

test "BufferPool: grow" {
    defer t.reset();

    var pool = try Pool.init(t.allocator, 1, 10);
    defer pool.deinit();

    {
        // grow a dynamic buffer
        var buf1 = try pool.alloc(15);
        @memcpy(buf1.data[0..5], "hello");
        const buf2 = try pool.grow(t.arena.allocator(), &buf1, 5, 20);
        defer pool.free(buf2);
        try t.expectEqual(20, buf2.data.len);
        try t.expectString("hello", buf2.data[0..5]);
    }

    {
        // grow a static buffer
        var buf1 = try pool.static(15);
        defer pool.free(buf1);
        @memcpy(buf1.data[0..6], "hello2");
        const buf2 = try pool.grow(t.arena.allocator(), &buf1, 6, 21);
        defer pool.free(buf2);
        try t.expectEqual(21, buf2.data.len);
        try t.expectString("hello2", buf2.data[0..6]);
    }

    {
        // grow a pooled buffer
        var buf1 = try pool.alloc(8);
        @memcpy(buf1.data[0..7], "hello2a");
        const buf2 = try pool.grow(t.arena.allocator(), &buf1, 7, 14);
        defer pool.free(buf2);
        try t.expectEqual(14, buf2.data.len);
        try t.expectString("hello2a", buf2.data[0..7]);
        try t.expectEqual(1, pool.available);
    }
}
