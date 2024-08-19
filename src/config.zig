pub const Config = struct {
    port: ?u16 = null,
    address: ?[]const u8 = null,
    unix_path: ?[]const u8 = null,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    cors: ?CORS = null,
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const Worker = struct {
        count: ?u16 = null,
        max_conn: ?u16 = null,
        min_conn: ?u16 = null,
        large_buffer_count: ?u16 = null,
        large_buffer_size: ?u32 = null,
        retain_allocated_bytes: ?usize = null,
    };
};
