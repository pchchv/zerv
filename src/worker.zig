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
};
