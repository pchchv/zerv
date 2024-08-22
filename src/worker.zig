const std = @import("std");

const zerv = @import("zerv.zig");

const Config = zerv.Config;
const Request = zerv.Request;
const Response = zerv.Response;

const BufferPool = @import("buffer.zig").Pool;

const net = std.net;
const posix = std.posix;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

// There's some shared logic between the NonBlocking and Blocking workers.
// Whatever we can de-duplicate, goes here.
const HTTPConnPool = struct {
    mut: Thread.Mutex,
    conns: []*HTTPConn,
    available: usize,
    allocator: Allocator,
    config: *const Config,
    buffer_pool: *BufferPool,
    retain_allocated_bytes: usize,
    http_mem_pool_mut: Thread.Mutex,
    http_mem_pool: std.heap.MemoryPool(HTTPConn),
    // The type is erased because it is necessary for Conn,
    // and thus Request and Response, to carry the type with them.
    // This is all about making the API cleaner.
    websocket: *anyopaque,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, websocket: *anyopaque, config: *const Config) !HTTPConnPool {
        const min = config.workers.min_conn orelse config.workers.max_conn orelse 64;
        var conns = try allocator.alloc(*HTTPConn, min);
        errdefer allocator.free(conns);

        var http_mem_pool = std.heap.MemoryPool(HTTPConn).init(allocator);
        errdefer http_mem_pool.deinit();

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                conns[i].deinit(allocator);
            }
        }

        for (0..min) |i| {
            const conn = try http_mem_pool.create();
            conn.* = try HTTPConn.init(allocator, buffer_pool, websocket, config);
            conns[i] = conn;
            initialized += 1;
        }

        return .{
            .mut = .{},
            .conns = conns,
            .config = config,
            .available = min,
            .websocket = websocket,
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .http_mem_pool = http_mem_pool,
            .http_mem_pool_mut = .{},
            .retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096,
        };
    }

    fn deinit(self: *HTTPConnPool) void {
        const allocator = self.allocator;
        // rest of the conns are "checked out" and owned by the Manager whichi will free them.
        for (self.conns[0..self.available]) |conn| {
            conn.deinit(allocator);
        }
        allocator.free(self.conns);
        self.http_mem_pool.deinit();
    }

    // Don't need thread safety in nonblocking.
    fn lock(self: *HTTPConnPool) void {
        if (comptime zerv.blockingMode()) {
            self.mut.lock();
        }
    }

    // Don't need thread safety in nonblocking.
    fn unlock(self: *HTTPConnPool) void {
        if (comptime zerv.blockingMode()) {
            self.mut.unlock();
        }
    }

    fn acquire(self: *HTTPConnPool) !*HTTPConn {
        const conns = self.conns;
        self.lock();
        const available = self.available;
        if (available == 0) {
            self.unlock();

            self.http_mem_pool_mut.lock();
            const conn = try self.http_mem_pool.create();
            self.http_mem_pool_mut.unlock();
            errdefer {
                self.http_mem_pool_mut.lock();
                self.http_mem_pool.destroy(conn);
                self.http_mem_pool_mut.unlock();
            }

            conn.* = try HTTPConn.init(self.allocator, self.buffer_pool, self.websocket, self.config);
            return conn;
        }

        const index = available - 1;
        const conn = conns[index];
        self.available = index;
        self.unlock();
        return conn;
    }

    fn release(self: *HTTPConnPool, conn: *HTTPConn) void {
        const conns = self.conns;

        self.lock();
        const available = self.available;
        if (available == conns.len) {
            self.unlock();
            conn.deinit(self.allocator);

            self.http_mem_pool_mut.lock();
            self.http_mem_pool.destroy(conn);
            self.http_mem_pool_mut.unlock();
            return;
        }

        conn.reset(self.retain_allocated_bytes);
        conns[available] = conn;
        self.available = available + 1;
        self.unlock();
    }
};

/// Wraps the socket with application-specific details,
/// such as information needed to manage the lifecycle of the connection (such as timeouts).
/// Connects are placed in a linked list, hence next/prev.
///
/// Connects can be reused (as part of a pool),
/// either for keepalive or for completely different tcp connections.
/// From a conn point of view, there is no difference, just need to `reset` between each request.
///
/// Conn contains the request and response state information needed to operate in non-blocking mode.
/// A pointer to conn is userdata passed to epoll/kqueue.
/// Should only be created via the HTTPConnPool worker.
pub const HTTPConn = struct {
    state: State,
    handover: Handover,
    timeout: u32, // unix timestamp (seconds) where this connection should timeout
    request_count: u64, // number of requests made on this connection (within a keepalive session)
    close: bool, // whether or not to close the connection after the response is sent
    stream: net.Stream,
    address: net.Address,
    // Data needed to parse a request. This contains pre-allocated memory, e.g.
    // as a read buffer and to store parsed headers. It also contains the state
    // necessary to parse the request over successive nonblocking read calls.
    req_state: Request.State,
    // Data needed to create the response. This contains pre-allocate memory, .e.
    // header buffer to write the buffer. It also contains the state necessary
    // to write the response over successive nonblocking write calls.
    res_state: Response.State,
    // Memory that is needed for the lifetime of a request, specifically from the
    // point where the request is parsed to after the response is sent, can be
    // allocated in this arena. An allocator for this arena is available to the
    // application as req.arena and res.arena.
    arena: *std.heap.ArenaAllocator,
    // This is our ws.Worker(WSH) but the type is erased so that Conn isn't
    // a generic. We don't want Conn to be a generic, because we don't want Response
    // to be generics since that would make using the library unecessarily complex
    // (especially since not everyone cares about websockets).
    ws_worker: *anyopaque,

    /// A connection can be in one of two states: active or keepalive.
    /// It begins and stays in the “active” state until a response is sent.
    /// Then, if the connection is not closed,
    /// it transitions to “keepalive” state until the first byte of a new request is received.
    /// The main purpose of the two different states is
    /// to support different keepalive_timeout and request_timeout.
    const State = enum {
        active,
        keepalive,
    };

    pub const Handover = union(enum) {
        disown,
        close,
        keepalive,
        websocket: *anyopaque,
    };

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws_worker: *anyopaque, config: *const Config) !HTTPConn {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);

        var req_state = try Request.State.init(allocator, arena, buffer_pool, &config.request);
        errdefer req_state.deinit(allocator);

        var res_state = try Response.State.init(allocator, &config.response);
        errdefer res_state.deinit(allocator);

        return .{
            .arena = arena,
            .close = false,
            .state = .active,
            .handover = .close,
            .stream = undefined,
            .address = undefined,
            .req_state = req_state,
            .res_state = res_state,
            .timeout = 0,
            .request_count = 0,
            .ws_worker = ws_worker,
        };
    }

    pub fn deinit(self: *HTTPConn, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.req_state.deinit(allocator);
        self.res_state.deinit(allocator);
    }

    pub fn keepalive(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    // reset getting put back into the pool.
    pub fn reset(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.close = false;
        self.handover = .close;
        self.stream = undefined;
        self.address = undefined;
        self.request_count = 0;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }
};

const EPoll = struct {
    q: i32,
    event_list: [128]EpollEvent,

    const linux = std.os.linux;
    const EpollEvent = linux.epoll_event;
    const Iterator = struct {
        index: usize,
        events: []EpollEvent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].data.ptr;
        }
    };

    fn init() !EPoll {
        return .{
            .event_list = undefined,
            .q = try posix.epoll_create1(0),
        };
    }

    fn deinit(self: EPoll) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *EPoll, fd: posix.fd_t) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorSignal(self: *EPoll, fd: posix.fd_t) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorRead(self: *EPoll, fd: posix.fd_t, data: usize, comptime rearm: bool) !void {
        const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = data } };
        return posix.epoll_ctl(self.q, op, fd, &event);
    }

    fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        var timeout: i32 = -1;
        if (timeout_sec) |sec| {
            if (sec > 2147483) {
                timeout = 2147483647; // max supported timeout by epoll_wait
            } else {
                timeout = sec * 1000;
            }
        }

        const event_count = posix.epoll_wait(self.q, event_list, timeout);
        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    fn remove(self: *EPoll, fd: posix.fd_t) !void {
        return posix.epoll_ctl(self.q, linux.EPOLL.CTL_DEL, fd, null);
    }
};

const KQueue = struct {
    q: i32,
    change_count: usize,
    change_buffer: [32]Kevent,
    event_list: [128]Kevent,
    const Kevent = posix.Kevent;

    const Iterator = struct {
        index: usize,
        events: []Kevent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].udata;
        }
    };

    fn init() !KQueue {
        return .{
            .q = try posix.kqueue(),
            .change_count = 0,
            .change_buffer = undefined,
            .event_list = undefined,
        };
    }

    fn deinit(self: KQueue) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    fn monitorSignal(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 1, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    fn monitorRead(self: *KQueue, fd: posix.socket_t, data: usize, comptime rearm: bool) !void {
        if (rearm) {
            // for websocket connections,
            // this is called in a thread-pool thread so cannot be queued up -
            // it needs to be immediately picked up since our worker could be in a wait() call.
            const event = Kevent{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH,
                .fflags = 0,
                .data = 0,
                .udata = data,
            };
            _ = try posix.kevent(self.q, &.{event}, &[_]Kevent{}, null);
        } else {
            try self.change(fd, data, posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH);
        }
    }

    fn remove(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.DELETE);
    }

    fn change(self: *KQueue, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
        var change_count = self.change_count;
        var change_buffer = &self.change_buffer;
        if (change_count == change_buffer.len) {
            // calling this with an empty event_list will return immediate
            _ = try posix.kevent(self.q, change_buffer, &[_]Kevent{}, null);
            change_count = 0;
        }
        change_buffer[change_count] = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = data,
        };
        self.change_count = change_count + 1;
    }

    fn wait(self: *KQueue, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
        const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
        self.change_count = 0;

        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }
};

pub fn List(comptime T: type) type {
    return struct {
        len: usize = 0,
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();
    };
}

pub fn timestamp() u32 {
    if (comptime @hasDecl(posix, "CLOCK") == false or posix.CLOCK == void) {
        return @intCast(std.time.timestamp());
    }
    var ts: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
    return @intCast(ts.sec);
}

fn initializeBufferPool(allocator: Allocator, config: *const Config) !*BufferPool {
    const large_buffer_count = config.workers.large_buffer_count orelse blk: {
        if (zerv.blockingMode()) {
            break :blk config.threadPoolCount();
        } else {
            break :blk 16;
        }
    };

    const large_buffer_size = config.workers.large_buffer_size orelse config.request.max_body_size orelse 65536;
    const buffer_pool = try allocator.create(BufferPool);
    errdefer allocator.destroy(buffer_pool);

    buffer_pool.* = try BufferPool.init(allocator, large_buffer_count, large_buffer_size);
    return buffer_pool;
}
