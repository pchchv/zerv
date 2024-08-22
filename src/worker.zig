const std = @import("std");
const ws = @import("websocket").server;

const zerv = @import("zerv.zig");
const metrics = @import("metrics.zig");

const Config = zerv.Config;
const Request = zerv.Request;
const Response = zerv.Response;

const BufferPool = @import("buffer.zig").Pool;

const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.zerv);

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const MAX_TIMEOUT = 2_147_483_647;

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

/// Pipe is used to communicate with the non-blocking worker.
/// This is necessary because the non-blocking worker is most likely locked in a loop (epoll/kqueue wait).
/// Therefore, one end of the pipe (the “read” end) is added to the loop.
/// The write end is used for two things:
///   1 - The zerv.Server(H) has a copy of the write end and can close it -
///       this is how the server signals the worker to shutdown.
///   2 - The non-blocking worker also has a copy of the end of the record.
///       It is used by the `serveHTTPRequest` method,
///       which is executed in a pool thread, to transfer control back to the worker.
const Signal = struct {
    pos: usize = 0,
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    mut: Thread.Mutex = .{},
    buf: [BUF_LEN]u8 = undefined,

    const BUF_LEN = 4096;
    const Iterator = struct {
        signal: *Signal,
        buf: []const u8,

        fn next(self: *Iterator) ?usize {
            const buf = self.buf;

            if (buf.len < @sizeOf(usize)) {
                if (buf.len == 0) {
                    self.signal.pos = 0;
                } else {
                    std.mem.copyForwards(u8, &self.signal.buf, buf);
                    self.signal.pos = buf.len;
                }
                return null;
            }

            const data = buf[0..@sizeOf(usize)];
            self.buf = buf[@sizeOf(usize)..];
            return std.mem.bytesToValue(usize, data);
        }
    };

    // Called in the thread-pool thread to let
    // the worker know that this connection is being handed back to the worker.
    fn write(self: *Signal, data: usize) !void {
        const fd = self.write_fd;
        const buf = std.mem.asBytes(&data);

        self.mut.lock();
        defer self.mut.unlock();

        var index: usize = 0;
        while (index < buf.len) {
            index += try posix.write(fd, buf[index..]);
        }
    }
};

pub fn List(comptime T: type) type {
    return struct {
        len: usize = 0,
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        pub fn insert(self: *Self, node: *T) void {
            if (self.tail) |tail| {
                tail.next = node;
                node.prev = tail;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }

            self.len += 1;
            node.next = null;
        }

        pub fn moveToTail(self: *Self, node: *T) void {
            const next = node.next orelse return;
            const prev = node.prev;
            if (prev) |p| {
                p.next = next;
            } else {
                self.head = next;
            }

            next.prev = prev;
            node.prev = self.tail;
            node.prev.?.next = node;
            self.tail = node;
            node.next = null;
        }

        pub fn remove(self: *Self, node: *T) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            node.prev = null;
            node.next = null;
            self.len -= 1;
        }
    };
}

pub fn Conn(comptime WSH: type) type {
    return struct {
        protocol: union(enum) {
            http: *HTTPConn,
            websocket: *ws.HandlerConn(WSH),
        },

        next: ?*Conn(WSH),
        prev: ?*Conn(WSH),

        const Self = @This();

        fn close(self: *Self) void {
            switch (self.protocol) {
                .http => |http_conn| posix.close(http_conn.stream.handle),
                .websocket => |hc| hc.conn.close(.{}) catch {},
            }
        }
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

fn ConnManager(comptime WSH: type) type {
    return struct {
        // Double linked list of Conn a worker is actively servicing.
        // “Active” connection is one where have received at least 1 byte of
        // a request and continue to be ‘active’ until a response is sent.
        active_list: List(Conn(WSH)),
        // Double linked list of Conn that the worker is monitoring.
        // Unlike “active” connections,
        // these connections are between requests
        // (which is possible due to keepalive).
        keepalive_list: List(Conn(WSH)),
        // Number of active connections.
        // This is the length of the list.
        len: usize,
        // A pool of HTTPConn objects.
        // The pool maintains a configured min # of these.
        http_conn_pool: HTTPConnPool,
        // For creating the Conn wrapper.
        // These are needed in the heap since they are
        // the ones that are passed to the event loop as data to be passed back.
        conn_mem_pool: std.heap.MemoryPool(Conn(WSH)),
        // Request and response processing may require larger buffers than
        // the static buffered of our req/res states.
        // BufferPool has large pre-allocated buffers that can be used,
        // and dynamic allocation will be performed when a larger buffer is emptied or needed.
        buffer_pool: *BufferPool,
        allocator: Allocator,
        timeout_request: u32,
        timeout_keepalive: u32,
        // How many bytes should be stored in the arena allocator between uses of keepalive.
        retain_allocated_bytes_keepalive: usize,

        const Self = @This();
        const TimeoutResult = struct {
            count: usize,
            timeout: ?u32,
        };

        fn init(allocator: Allocator, websocket: *anyopaque, config: *const Config) !Self {
            var buffer_pool = try initializeBufferPool(allocator, config);
            errdefer buffer_pool.deinit();

            var conn_mem_pool = std.heap.MemoryPool(Conn(WSH)).init(allocator);
            errdefer conn_mem_pool.deinit();

            const http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, config);
            errdefer http_conn_pool.deinit();

            const retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096;
            const retain_allocated_bytes_keepalive = @max(retain_allocated_bytes, 8192);

            return .{
                .len = 0,
                .active_list = .{},
                .keepalive_list = .{},
                .allocator = allocator,
                .buffer_pool = buffer_pool,
                .conn_mem_pool = conn_mem_pool,
                .http_conn_pool = http_conn_pool,
                .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
                .timeout_request = config.timeout.request orelse MAX_TIMEOUT,
                .timeout_keepalive = config.timeout.keepalive orelse MAX_TIMEOUT,
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.buffer_pool.deinit();
            self.conn_mem_pool.deinit();
            self.http_conn_pool.deinit();
            allocator.destroy(self.buffer_pool);
        }

        fn new(self: *Self, now: u32) !*Conn(WSH) {
            const conn = try self.conn_mem_pool.create();
            errdefer self.conn_mem_pool.destroy(conn);

            const http_conn = try self.http_conn_pool.acquire();
            http_conn.state = .active;
            http_conn.request_count = 1;
            http_conn.timeout = now + self.timeout_request;

            self.len += 1;
            conn.* = .{
                .next = null,
                .prev = null,
                .protocol = .{ .http = http_conn },
            };
            self.active_list.insert(conn);
            return conn;
        }

        fn close(self: *Self, conn: *Conn(WSH)) void {
            conn.close();
            self.disown(conn);
        }

        fn active(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;
            if (http_conn.state == .active) return;

            // The Connection moves from the keepalive state to the active state.

            http_conn.state = .active;
            http_conn.request_count += 1;
            http_conn.timeout = now + self.timeout_request;

            self.keepalive_list.remove(conn);
            self.active_list.insert(conn);
        }

        fn keepalive(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;

            http_conn.keepalive(self.retain_allocated_bytes_keepalive);
            http_conn.state = .keepalive;
            http_conn.timeout = now + self.timeout_keepalive;

            self.active_list.remove(conn);
            self.keepalive_list.insert(conn);
        }

        fn disown(self: *Self, conn: *Conn(WSH)) void {
            switch (conn.protocol) {
                .http => |http_conn| {
                    switch (http_conn.state) {
                        .active => self.active_list.remove(conn),
                        // A connection that is in keepalive mode cannot be abandoned,
                        // but it can be closed (by timeout),
                        // and a call to close will cause a disown.
                        .keepalive => self.active_list.remove(conn),
                    }
                    self.http_conn_pool.release(http_conn);
                },
                .websocket => {},
            }

            self.len -= 1;
            self.conn_mem_pool.destroy(conn);
        }

        fn shutdown(self: *Self) void {
            self.shutdownList(&self.active_list);
            self.shutdownList(&self.keepalive_list);
        }

        fn shutdownList(self: *Self, list: *List(Conn(WSH))) void {
            const allocator = self.allocator;
            var conn = list.head;
            while (conn) |c| {
                conn = c.next;
                const http_conn = c.protocol.http;
                posix.close(http_conn.stream.handle);
                http_conn.deinit(allocator);
            }
        }

        // Enforces timeouts, and returns when the next timeout should be checked.
        fn prepareToWait(self: *Self, now: u32) ?i32 {
            const next_active = self.enforceTimeout(&self.active_list, now);
            const next_keepalive = self.enforceTimeout(&self.keepalive_list, now);

            {
                const next_active_count = next_active.count;
                if (next_active_count > 0) {
                    metrics.timeoutActive(next_active_count);
                }
                const next_keepalive_count = next_keepalive.count;
                if (next_keepalive_count > 0) {
                    metrics.timeoutKeepalive(next_active_count);
                }
            }

            const next_active_timeout = next_active.timeout;
            const next_keepalive_timeout = next_keepalive.timeout;
            if (next_active_timeout == null and next_keepalive_timeout == null) {
                return null;
            }

            const next = @min(next_active_timeout orelse MAX_TIMEOUT, next_keepalive_timeout orelse MAX_TIMEOUT);
            if (next < now) {
                // can happen if a socket was just about to time out when enforceTimeout was called
                return 1;
            }

            return @intCast(next - now);
        }

        fn upgrade(self: *Self, conn: *Conn(WSH), hc: *ws.HandlerConn(WSH)) void {
            std.debug.assert(conn.protocol.http.state == .active);
            self.active_list.remove(conn);
            self.http_conn_pool.release(conn.protocol.http);
            conn.protocol = .{ .websocket = hc };
        }

        // The lists are ordered from soonest to timeout to last,
        // once a connection is found that has not timed out, it can be break;
        // This returns the next timeout.
        // Called only in the active and keepalive lists,
        // which handle only http connections.
        fn enforceTimeout(self: *Self, list: *List(Conn(WSH)), now: u32) TimeoutResult {
            var conn = list.head;
            var count: usize = 0;
            while (conn) |c| {
                const timeout = c.protocol.http.timeout;
                if (timeout > now) {
                    return .{ .count = count, .timeout = timeout };
                }
                count += 1;
                conn = c.next;
                self.close(c);
            }
            return .{ .count = count, .timeout = null };
        }
    };
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

fn writeError(conn: *HTTPConn, comptime status: u16, comptime msg: []const u8) !void {
    var i: usize = 0;
    const socket = conn.stream.handle;
    const response = std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, msg.len, msg });
    const timeout = std.mem.toBytes(std.posix.timeval{ .sec = 5, .usec = 0 });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    while (i < response.len) {
        const n = posix.write(socket, response[i..]) catch |err| switch (err) {
            error.WouldBlock => return error.Timeout,
            else => return err,
        };

        if (n == 0) {
            return error.Closed;
        }

        i += n;
    }
}

fn serverError(conn: *HTTPConn, comptime log_fmt: []const u8, err: anyerror) !void {
    log.err("server error: " ++ log_fmt, .{err});
    metrics.internalError();
    return writeError(conn, 500, "Internal Server Error");
}

// Handles parsing errors.
// If this function returns true, it means that Conn has a write-ready body.
// In this case, the worker (blocking or non-blocking) will want to send a response.
// If false is returned, the worker probably wants to close the connection.
// This function ensures that both blocking and non-blocking workers handle these errors with the same response.
fn requestParseError(conn: *HTTPConn, err: anyerror) !void {
    switch (err) {
        error.HeaderTooBig => {
            metrics.invalidRequest();
            return writeError(conn, 431, "Request header is too big");
        },
        error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine, error.InvalidContentLength => {
            metrics.invalidRequest();
            return writeError(conn, 400, "Invalid Request");
        },
        error.BrokenPipe, error.ConnectionClosed, error.ConnectionResetByPeer => return,
        else => return serverError(conn, "unknown read/parse error: {}", err),
    }
    log.err("unknown parse error: {}", .{err});
    return err;
}
