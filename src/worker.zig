const std = @import("std");

const zerv = @import("zerv.zig");

const Config = zerv.Config;
const Request = zerv.Request;
const Response = zerv.Response;

const BufferPool = @import("buffer.zig").Pool;

const Allocator = std.mem.Allocator;

const net = std.net;

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
};
