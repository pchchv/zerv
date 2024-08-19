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
};
