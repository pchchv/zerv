const std = @import("std");
const build = @import("build");
const builtin = @import("builtin");

const url = @import("url.zig");
const Metrics = @import("metrics.zig");
const worker = @import("worker.zig");

pub const websocket = @import("websocket");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const key_value = @import("key_value.zig");

pub const Config = @import("config.zig").Config;

pub const Url = url.Url;
pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;

const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const asUint = url.asUint;

const ThreadPool = @import("thread_pool.zig").ThreadPool;

const force_blocking: bool = if (@hasDecl(build, "zerv_blocking")) build.zerv_blocking else false;

const MAX_REQUEST_COUNT = 4_294_967_295;

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
};

pub const ContentType = enum {
    BINARY,
    CSS,
    CSV,
    EOT,
    EVENTS,
    GIF,
    GZ,
    HTML,
    ICO,
    JPG,
    JS,
    JSON,
    OTF,
    PDF,
    PNG,
    SVG,
    TAR,
    TEXT,
    TTF,
    WASM,
    WEBP,
    WOFF,
    WOFF2,
    XML,
    UNKNOWN,

    pub fn forExtension(ext: []const u8) ContentType {
        if (ext.len == 0) return .UNKNOWN;
        const temp = if (ext[0] == '.') ext[1..] else ext;
        if (temp.len > 5) return .UNKNOWN;

        var normalized: [5]u8 = undefined;
        for (temp, 0..) |c, i| {
            normalized[i] = std.ascii.toLower(c);
        }

        switch (temp.len) {
            2 => {
                switch (@as(u16, @bitCast(normalized[0..2].*))) {
                    asUint("js") => return .JS,
                    asUint("gz") => return .GZ,
                    else => return .UNKNOWN,
                }
            },
            3 => {
                switch (@as(u24, @bitCast(normalized[0..3].*))) {
                    asUint("css") => return .CSS,
                    asUint("csv") => return .CSV,
                    asUint("eot") => return .EOT,
                    asUint("gif") => return .GIF,
                    asUint("htm") => return .HTML,
                    asUint("ico") => return .ICO,
                    asUint("jpg") => return .JPG,
                    asUint("otf") => return .OTF,
                    asUint("pdf") => return .PDF,
                    asUint("png") => return .PNG,
                    asUint("svg") => return .SVG,
                    asUint("tar") => return .TAR,
                    asUint("ttf") => return .TTF,
                    asUint("xml") => return .XML,
                    else => return .UNKNOWN,
                }
            },
            4 => {
                switch (@as(u32, @bitCast(normalized[0..4].*))) {
                    asUint("jpeg") => return .JPG,
                    asUint("json") => return .JSON,
                    asUint("html") => return .HTML,
                    asUint("text") => return .TEXT,
                    asUint("wasm") => return .WASM,
                    asUint("woff") => return .WOFF,
                    asUint("webp") => return .WEBP,
                    else => return .UNKNOWN,
                }
            },
            5 => {
                switch (@as(u40, @bitCast(normalized[0..5].*))) {
                    asUint("woff2") => return .WOFF2,
                    else => return .UNKNOWN,
                }
            },
            else => return .UNKNOWN,
        }
        return .UNKNOWN;
    }

    pub fn forFile(file_name: []const u8) ContentType {
        return forExtension(std.fs.path.extension(file_name));
    }
};

// If WebsocketHandler is not specified,
// give it a dummy handler just to make the code compile.
pub const DummyWebsocketHandler = struct {
    pub fn clientMessage(_: DummyWebsocketHandler, _: []const u8) !void {}
};

pub const MiddlewareConfig = struct {
    arena: Allocator,
    allocator: Allocator,
};

pub fn blockingMode() bool {
    if (force_blocking) {
        return true;
    }
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
        else => true,
    };
}

pub fn writeMetrics(writer: anytype) !void {
    return Metrics.write(writer);
}

/// When Server(handler: type) is initialized with a non-void handler,
/// the ActionContext will either be defined by the handler,
/// or will be the handler itself.
/// So for this type,
/// “ActionContext” can either be the handler or the ActionContext from the server.
pub fn Action(comptime ActionContext: type) type {
    if (ActionContext == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (ActionContext, *Request, *Response) anyerror!void;
}

pub fn Server(comptime H: type) type {
    const Handler = switch (@typeInfo(H)) {
        .Struct => H,
        .Pointer => |ptr| ptr.child,
        .Void => void,
        else => @compileError("Server handler must be a struct, got: " ++ @tagName(@typeInfo(H))),
    };

    const ActionArg = if (comptime std.meta.hasFn(Handler, "dispatch")) @typeInfo(@TypeOf(Handler.dispatch)).Fn.params[1].type.? else Action(H);
    const WebsocketHandler = if (Handler != void and comptime @hasDecl(Handler, "WebsocketHandler")) Handler.WebsocketHandler else DummyWebsocketHandler;

    return struct {
        const TP = if (blockingMode()) ThreadPool(worker.Blocking(*Self, WebsocketHandler).handleConnection) else ThreadPool(worker.NonBlocking(*Self, WebsocketHandler).processData);

        handler: H,
        config: Config,
        arena: Allocator,
        allocator: Allocator,
        _router: Router(H, ActionArg),
        _mut: Thread.Mutex,
        _cond: Thread.Condition,
        _thread_pool: *TP,
        _signals: []posix.fd_t,
        _max_request_per_connection: u64,
        _websocket_state: websocket.server.WorkerState,
        _middlewares: std.SinglyLinkedList(Middleware(H)),

        const Self = @This();

        pub fn init(allocator: Allocator, config: Config, handler: H) !Self {
            // Most things can do dynamic allocation and should be able to free memory when it runs out.
            // Only used for things that are created at startup and will not be dynamically grow/shrink.
            const arena = try allocator.create(std.heap.ArenaAllocator);
            errdefer allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const thread_pool = try TP.init(arena.allocator(), .{
                .count = config.threadPoolCount(),
                .backlog = config.thread_pool.backlog orelse 500,
                .buffer_size = config.thread_pool.buffer_size orelse 32_768,
            });

            const signals = try arena.allocator().alloc(posix.fd_t, config.workerCount());

            const default_dispatcher = if (comptime Handler == void) defaultDispatcher else defaultDispatcherWithHandler;

            // do not pass arena.allocator to WorkerState,
            // it needs to be able to allocate and free at will.
            var websocket_state = try websocket.server.WorkerState.init(allocator, .{
                .max_message_size = config.websocket.max_message_size,
                .buffers = .{
                    .small_size = config.websocket.small_buffer_size,
                    .small_pool = config.websocket.small_buffer_pool,
                    .large_size = config.websocket.large_buffer_size,
                    .large_pool = config.websocket.large_buffer_pool,
                },
                // disable handshake memory allocation since zerv is handling the handshake request directly
                .handshake = .{
                    .count = 0,
                    .max_size = 0,
                    .max_headers = 0,
                },
            });
            errdefer websocket_state.deinit();

            return .{
                .config = config,
                .handler = handler,
                .allocator = allocator,
                .arena = arena.allocator(),
                ._mut = .{},
                ._cond = .{},
                ._middlewares = .{},
                ._signals = signals,
                ._thread_pool = thread_pool,
                ._websocket_state = websocket_state,
                ._router = try Router(H, ActionArg).init(arena.allocator(), default_dispatcher, handler),
                ._max_request_per_connection = config.timeout.request_count orelse MAX_REQUEST_COUNT,
            };
        }

        pub fn deinit(self: *Self) void {
            self._thread_pool.stop();
            self._websocket_state.deinit();

            var node = self._middlewares.first;
            while (node) |n| {
                n.data.deinit();
                node = n.next;
            }

            const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
            arena.deinit();
            self.allocator.destroy(arena);
        }

        fn defaultDispatcher(action: ActionArg, req: *Request, res: *Response) !void {
            return action(req, res);
        }

        fn defaultDispatcherWithHandler(handler: H, action: ActionArg, req: *Request, res: *Response) !void {
            if (comptime std.meta.hasFn(Handler, "dispatch")) {
                return handler.dispatch(action, req, res);
            }
            return action(handler, req, res);
        }

        pub fn listen(self: *Self) !void {
            // incase "stop" is waiting
            defer self._cond.signal();
            self._mut.lock();

            var no_delay = true;
            const config = self.config;
            const address = blk: {
                if (config.unix_path) |unix_path| {
                    if (comptime std.net.has_unix_sockets == false) {
                        return error.UnixPathNotSupported;
                    }
                    no_delay = false;
                    std.fs.deleteFileAbsolute(unix_path) catch {};
                    break :blk try net.Address.initUnix(unix_path);
                } else {
                    const listen_port = config.port orelse 5882;
                    const listen_address = config.address orelse "127.0.0.1";
                    break :blk try net.Address.parseIp(listen_address, listen_port);
                }
            };

            const socket = blk: {
                var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
                if (blockingMode() == false) sock_flags |= posix.SOCK.NONBLOCK;

                const proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
                break :blk try posix.socket(address.any.family, sock_flags, proto);
            };

            if (no_delay) {
                try posix.setsockopt(socket, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
            }

            if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(posix.SO, "REUSEPORT")) {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            } else {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            }

            {
                const socklen = address.getOsSockLen();
                try posix.bind(socket, &address.any, socklen);
                try posix.listen(socket, 1024); // kernel backlog
            }

            const allocator = self.allocator;

            if (comptime blockingMode()) {
                errdefer posix.close(socket);
                var w = try worker.Blocking(*Self, WebsocketHandler).init(allocator, self, &config);
                defer w.deinit();

                const thrd = try Thread.spawn(.{}, worker.Blocking(*Self, WebsocketHandler).listen, .{ &w, socket });

                // incase listenInNewThread was used and is waiting for us to start
                self._cond.signal();

                // we shutdown our blocking worker by closing the listening socket
                self._signals[0] = socket;
                self._mut.unlock();
                thrd.join();
            } else {
                defer posix.close(socket);
                const Worker = worker.NonBlocking(*Self, WebsocketHandler);
                var signals = self._signals;
                const worker_count = signals.len;
                const workers = try self.arena.alloc(Worker, worker_count);
                const threads = try self.arena.alloc(Thread, worker_count);

                var started: usize = 0;
                errdefer for (0..started) |i| {
                    // on success, these will be closed by a call to stop();
                    posix.close(signals[i]);
                };

                defer {
                    for (0..started) |i| {
                        workers[i].deinit();
                    }
                }

                for (0..workers.len) |i| {
                    const pipe = try posix.pipe2(.{ .NONBLOCK = true });
                    signals[i] = pipe[1];
                    errdefer posix.close(pipe[1]);

                    workers[i] = try Worker.init(allocator, pipe, self, &config);
                    errdefer workers[i].deinit();

                    threads[i] = try Thread.spawn(.{}, Worker.run, .{ &workers[i], socket });
                    started += 1;
                }

                // incase listenInNewThread was used and is waiting for us to start
                self._cond.signal();
                self._mut.unlock();

                for (threads) |thrd| {
                    thrd.join();
                }
            }
        }

        pub fn listenInNewThread(self: *Self) !std.Thread {
            self._mut.lock();
            defer self._mut.unlock();
            const thrd = try std.Thread.spawn(.{}, listen, .{self});

            // do not return until listen() signals that the server is up
            self._cond.wait(&self._mut);

            return thrd;
        }

        pub fn stop(self: *Self) void {
            self._mut.lock();
            defer self._mut.unlock();
            for (self._signals) |s| {
                if (blockingMode()) {
                    // necessary to unblock accept on linux
                    // (which might not be that necessary since, on Linux,
                    // NonBlocking should be used)
                    posix.shutdown(s, .recv) catch {};
                }
                posix.close(s);
            }
        }
    };
}

pub fn Middleware(comptime H: type) type {
    return struct {
        ptr: *anyopaque,
        deinitFn: *const fn (ptr: *anyopaque) void,
        executeFn: *const fn (ptr: *anyopaque, req: *Request, res: *Response, executor: *Server(H).Executor) anyerror!void,

        const Self = @This();

        pub fn init(ptr: anytype) Self {
            const T = @TypeOf(ptr);
            const ptr_info = @typeInfo(T);
            const gen = struct {
                pub fn deinit(pointer: *anyopaque) void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    if (std.meta.hasMethod(T, "deinit")) {
                        return ptr_info.Pointer.child.deinit(self);
                    }
                }

                pub fn execute(pointer: *anyopaque, req: *Request, res: *Response, executor: *Server(H).Executor) anyerror!void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    return ptr_info.Pointer.child.execute(self, req, res, executor);
                }
            };

            return .{
                .ptr = ptr,
                .deinitFn = gen.deinit,
                .executeFn = gen.execute,
            };
        }

        pub fn deinit(self: Self) void {
            self.deinitFn(self.ptr);
        }

        pub fn execute(self: Self, req: *Request, res: *Response, executor: *Server(H).Executor) !void {
            return self.executeFn(self.ptr, req, res, executor);
        }
    };
}
