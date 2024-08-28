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
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const asUint = url.asUint;

const ThreadPool = @import("thread_pool.zig").ThreadPool;

const force_blocking: bool = if (@hasDecl(build, "zerv_blocking")) build.zerv_blocking else false;

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
    };
}

pub fn Middleware(comptime H: type) type {
    return struct {
        ptr: *anyopaque,
        deinitFn: *const fn (ptr: *anyopaque) void,
        executeFn: *const fn (ptr: *anyopaque, req: *Request, res: *Response, executor: *Server(H).Executor) anyerror!void,

        const Self = @This();
    };
}
