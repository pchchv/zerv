// Internal helpers used by this library
const std = @import("std");

const zerv = @import("zerv.zig");

const Allocator = std.mem.Allocator;

const Conn = @import("worker.zig").HTTPConn;
const BufferPool = @import("buffer.zig").Pool;

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const allocator = std.testing.allocator;

pub var arena = std.heap.ArenaAllocator.init(allocator);

pub const Context = struct {
    fake: bool,
    conn: *Conn,
    to_read_pos: usize,
    closed: bool = false,
    stream: std.net.Stream, // the stream that the server gets
    client: std.net.Stream, // the client (e.g. browser stream)
    to_read: std.ArrayList(u8),
    arena: *std.heap.ArenaAllocator,
    _random: ?std.Random.DefaultPrng = null,

    pub fn allocInit(ctx_allocator: Allocator, config_: zerv.Config) Context {
        var pair: [2]c_int = undefined;
        const rc = std.c.socketpair(std.posix.AF.LOCAL, std.posix.SOCK.STREAM, 0, &pair);
        if (rc != 0) {
            @panic("socketpair fail");
        }

        {
            const timeout = std.mem.toBytes(std.posix.timeval{
                .sec = 0,
                .usec = 20_000,
            });
            std.posix.setsockopt(pair[0], std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout) catch unreachable;
            std.posix.setsockopt(pair[0], std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout) catch unreachable;
            std.posix.setsockopt(pair[1], std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout) catch unreachable;
            std.posix.setsockopt(pair[1], std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout) catch unreachable;

            // for request.fuzz, which does up to an 8K write. Not sure why this has
            // to be so much more but on linux, even a 10K SNDBUF results in WOULD_BLOCK.
            std.posix.setsockopt(pair[1], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 20_000))) catch unreachable;
        }

        const server = std.net.Stream{ .handle = pair[0] };
        const client = std.net.Stream{ .handle = pair[1] };

        var ctx_arena = ctx_allocator.create(std.heap.ArenaAllocator) catch unreachable;
        ctx_arena.* = std.heap.ArenaAllocator.init(ctx_allocator);

        const aa = ctx_arena.allocator();

        const bp = aa.create(BufferPool) catch unreachable;
        bp.* = BufferPool.init(aa, 2, 256) catch unreachable;

        var config = config_;
        {
            // Various parts of the code using pretty generous defaults. For tests
            // we can use more conservative values.
            const cw = config.workers;
            if (cw.count == null) config.workers.count = 2;
            if (cw.max_conn == null) config.workers.max_conn = 2;
            if (cw.min_conn == null) config.workers.min_conn = 1;
            if (cw.large_buffer_count == null) config.workers.large_buffer_count = 1;
            if (cw.large_buffer_size == null) config.workers.large_buffer_size = 256;
        }

        const req_state = zerv.Request.State.init(aa, bp, &config.request) catch unreachable;
        const res_state = zerv.Response.State.init(aa, &config.response) catch unreachable;

        const conn = aa.create(Conn) catch unreachable;
        conn.* = .{
            .state = .active,
            .handover = .close,
            .stream = server,
            .address = std.net.Address.initIp4([_]u8{ 127, 0, 0, 200 }, 0),
            .req_state = req_state,
            .res_state = res_state,
            .timeout = 0,
            .request_count = 0,
            .close = false,
            .ws_worker = undefined,
            .conn_arena = ctx_arena,
            .req_arena = std.heap.ArenaAllocator.init(aa),
        };

        return .{
            .conn = conn,
            .arena = ctx_arena,
            .stream = server,
            .client = client,
            .fake = false,
            .to_read_pos = 0,
            .to_read = std.ArrayList(u8).init(aa),
        };
    }

    pub fn init(config: zerv.Config) Context {
        return allocInit(allocator, config);
    }

    pub fn deinit(self: *Context) void {
        if (self.closed == false) {
            self.closed = true;
            self.stream.close();
        }
        self.client.close();

        const ctx_allocator = arena.child_allocator;
        self.arena.deinit();
        ctx_allocator.destroy(self.arena);
    }

    // force the server side socket to be closed,
    // which helps reading-test know that there's no more data.
    pub fn close(self: *Context) void {
        if (self.closed == false) {
            self.closed = true;
            self.stream.close();
        }
    }

    pub fn write(self: *Context, data: []const u8) void {
        if (self.fake) {
            self.to_read.appendSlice(data) catch unreachable;
        } else {
            self.client.writeAll(data) catch unreachable;
        }
    }

    pub fn read(self: Context, a: Allocator) !std.ArrayList(u8) {
        var buf: [1024]u8 = undefined;
        var arr = std.ArrayList(u8).init(a);

        while (true) {
            const n = self.client.read(&buf) catch |err| switch (err) {
                error.WouldBlock => return arr,
                else => return err,
            };
            if (n == 0) return arr;
            try arr.appendSlice(buf[0..n]);
        }
        unreachable;
    }
};

pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub fn randomString(random: std.Random, a: Allocator, max: usize) []u8 {
    var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
    const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_";
    for (0..buf.len) |i| {
        buf[i] = valid[random.uintAtMost(usize, valid.len - 1)];
    }
    return buf;
}

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.Random.DefaultPrng.init(seed);
}
