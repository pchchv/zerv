const std = @import("std");

const zerv = @import("zerv.zig");

const Params = @import("params.zig").Params;

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

fn RouteConfig(comptime Handler: type, comptime Action: type) type {
    const Dispatcher = zerv.Dispatcher(Handler, Action);
    return struct {
        data: ?*const anyopaque = null,
        handler: ?Handler = null,
        dispatcher: ?Dispatcher = null,
        middlewares: ?[]const zerv.Middleware(Handler) = null,
        middleware_strategy: ?MiddlewareStrategy = null,
    };
}

pub fn Part(comptime A: type) type {
    return struct {
        action: ?A,
        glob: ?*Part(A),
        glob_all: bool,
        param_part: ?*Part(A),
        param_names: ?[][]const u8,
        parts: StringHashMap(Part(A)),

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .glob = null,
                .glob_all = false,
                .action = null,
                .param_part = null,
                .param_names = null,
                .parts = StringHashMap(Part(A)).init(allocator),
            };
        }

        pub fn clear(self: *Self, allocator: Allocator) void {
            self.glob = null;
            self.glob_all = false;
            self.action = null;
            self.param_part = null;
            self.param_names = null;
            self.parts = StringHashMap(Part(A)).init(allocator);
        }
    };
}

pub fn Router(comptime Handler: type, comptime Action: type) type {
    const Dispatcher = zerv.Dispatcher(Handler, Action);
    const DispatchableAction = zerv.DispatchableAction(Handler, Action);

    return struct {
        _arena: *std.heap.ArenaAllocator,
        _aa: Allocator,
        _get: Part(DispatchableAction),
        _put: Part(DispatchableAction),
        _post: Part(DispatchableAction),
        _head: Part(DispatchableAction),
        _patch: Part(DispatchableAction),
        _trace: Part(DispatchableAction),
        _delete: Part(DispatchableAction),
        _options: Part(DispatchableAction),
        _default_handler: Handler,
        _default_dispatcher: Dispatcher,

        const Self = @This();

        pub fn init(allocator: Allocator, default_dispatcher: Dispatcher, default_handler: Handler) !Self {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            const aa = arena.allocator();

            return Self{
                ._arena = arena,
                ._aa = aa,
                ._default_handler = default_handler,
                ._default_dispatcher = default_dispatcher,
                ._get = try Part(DispatchableAction).init(aa),
                ._head = try Part(DispatchableAction).init(aa),
                ._post = try Part(DispatchableAction).init(aa),
                ._put = try Part(DispatchableAction).init(aa),
                ._patch = try Part(DispatchableAction).init(aa),
                ._trace = try Part(DispatchableAction).init(aa),
                ._delete = try Part(DispatchableAction).init(aa),
                ._options = try Part(DispatchableAction).init(aa),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self._arena.deinit();
            allocator.destroy(self._arena);
        }

        pub fn dispatcher(self: *Self, d: Dispatcher) void {
            self._default_dispatcher = d;
        }

        pub fn handler(self: *Self, h: Handler) void {
            self.default_handler = h;
        }

        pub fn route(self: Self, method: zerv.Method, url: []const u8, params: *Params) ?DispatchableAction {
            return switch (method) {
                zerv.Method.GET => getRoute(DispatchableAction, self._get, url, params),
                zerv.Method.POST => getRoute(DispatchableAction, self._post, url, params),
                zerv.Method.PUT => getRoute(DispatchableAction, self._put, url, params),
                zerv.Method.DELETE => getRoute(DispatchableAction, self._delete, url, params),
                zerv.Method.PATCH => getRoute(DispatchableAction, self._patch, url, params),
                zerv.Method.HEAD => getRoute(DispatchableAction, self._head, url, params),
                zerv.Method.OPTIONS => getRoute(DispatchableAction, self._options, url, params),
            };
        }

        pub fn get(self: *Self, path: []const u8, action: Action) void {
            self.getC(path, action, .{});
        }

        pub fn tryGet(self: *Self, path: []const u8, action: Action) !void {
            return self.tryGetC(path, action, .{});
        }

        pub fn getC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryGetC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryGetC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._get, path, da);
        }

        pub fn put(self: *Self, path: []const u8, action: Action) void {
            self.putC(path, action, .{});
        }

        pub fn tryPut(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPutC(path, action, .{});
        }

        pub fn putC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryPutC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryPutC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._put, path, da);
        }

        pub fn post(self: *Self, path: []const u8, action: Action) void {
            self.postC(path, action, .{});
        }

        pub fn tryPost(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPostC(path, action, .{});
        }

        pub fn postC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryPostC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryPostC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._post, path, da);
        }

        pub fn head(self: *Self, path: []const u8, action: Action) void {
            self.headC(path, action, .{});
        }

        pub fn tryHead(self: *Self, path: []const u8, action: Action) !void {
            return self.tryHeadC(path, action, .{});
        }

        pub fn headC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryHeadC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryHeadC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._head, path, da);
        }

        pub fn patch(self: *Self, path: []const u8, action: Action) void {
            self.patchC(path, action, .{});
        }

        pub fn tryPatch(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPatchC(path, action, .{});
        }

        pub fn patchC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryPatchC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryPatchC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._patch, path, da);
        }

        pub fn trace(self: *Self, path: []const u8, action: Action) void {
            self.traceC(path, action, .{});
        }

        pub fn tryTrace(self: *Self, path: []const u8, action: Action) !void {
            return self.tryTraceC(path, action, .{});
        }

        pub fn traceC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryTraceC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryTraceC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._trace, path, da);
        }

        pub fn delete(self: *Self, path: []const u8, action: Action) void {
            self.deleteC(path, action, .{});
        }

        pub fn tryDelete(self: *Self, path: []const u8, action: Action) !void {
            return self.tryDeleteC(path, action, .{});
        }

        pub fn deleteC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryDeleteC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryDeleteC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._delete, path, da);
        }

        pub fn options(self: *Self, path: []const u8, action: Action) void {
            self.optionsC(path, action, .{});
        }

        pub fn tryOptions(self: *Self, path: []const u8, action: Action) !void {
            return self.tryOptionsC(path, action, .{});
        }

        pub fn optionsC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryOptionsC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryOptionsC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            const da = DispatchableAction{
                .action = action,
                .handler = config.handler orelse self._default_handler,
                .dispatcher = config.dispatcher orelse self._default_dispatcher,
            };
            try addRoute(DispatchableAction, self._aa, &self._options, path, da);
        }

        pub fn all(self: *Self, path: []const u8, action: Action) void {
            self.allC(path, action, .{});
        }

        pub fn tryAll(self: *Self, path: []const u8, action: Action) !void {
            return self.tryAllC(path, action, .{});
        }

        pub fn allC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self.tryAllC(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryAllC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            try self.tryGetC(path, action, config);
            try self.tryPutC(path, action, config);
            try self.tryPostC(path, action, config);
            try self.tryHeadC(path, action, config);
            try self.tryPatchC(path, action, config);
            try self.tryTraceC(path, action, config);
            try self.tryDeleteC(path, action, config);
            try self.tryOptionsC(path, action, config);
        }

        pub fn group(self: *Self, prefix: []const u8, config: Config(Handler, Action)) Group(Handler, Action) {
            return Group(Handler, Action).init(self, prefix, config);
        }
    };
}

pub fn Group(comptime Handler: type, comptime Action: type) type {
    const RC = RouteConfig(Handler, Action);
    return struct {
        _allocator: Allocator,
        _prefix: []const u8,
        _router: *Router(Handler, Action),
        _config: RouteConfig(Handler, Action),

        const Self = @This();

        fn init(router: *Router(Handler, Action), prefix: []const u8, config: RC) Self {
            return .{
                ._prefix = prefix,
                ._router = router,
                ._config = config,
                ._allocator = router._allocator,
            };
        }

        pub fn get(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.get(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryGet(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryGet(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn put(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.put(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryPut(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryPut(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn post(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.post(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryPost(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryPost(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn patch(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.patch(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryPatch(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryPatch(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn head(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.head(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryHead(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryHead(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn trace(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.trace(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryTrace(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryTrace(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn delete(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.delete(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryDelete(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryDelete(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn options(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.options(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryOptions(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryOptions(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        pub fn all(self: *Self, path: []const u8, action: Action, override: RC) void {
            self._router.all(self.createPath(path), action, self.mergeConfig(override));
        }
        pub fn tryAll(self: *Self, path: []const u8, action: Action, override: RC) !void {
            return self._router.tryAll(self.tryCreatePath(path), action, self.tryMergeConfig(override));
        }

        fn createPath(self: *Self, path: []const u8) []const u8 {
            return self.tryCreatePath(path) catch unreachable;
        }

        fn tryCreatePath(self: *Self, path: []const u8) ![]const u8 {
            var prefix = self._prefix;
            if (prefix.len == 0) {
                return path;
            }

            if (path.len == 0) {
                return prefix;
            }

            // prefix = /admin/
            // path = /users/
            // result ==> /admin/users/  NOT   /admin//users/
            if (prefix[prefix.len - 1] == '/' and path[0] == '/') {
                prefix = prefix[0 .. prefix.len - 1];
            }

            const joined = try self._allocator.alloc(u8, prefix.len + path.len);
            @memcpy(joined[0..prefix.len], prefix);
            @memcpy(joined[prefix.len..], path);
            return joined;
        }

        fn mergeConfig(self: *Self, override: RC) RC {
            return self.tryMergeConfig(override) catch unreachable;
        }

        fn tryMergeConfig(self: *Self, override: RC) !RC {
            return .{
                .data = override.data orelse self._config.data,
                .handler = override.handler orelse self._config.handler,
                .dispatcher = override.dispatcher orelse self._config.dispatcher,
                .middlewares = try self._router.mergeMiddleware(self._config.middlewares orelse &.{}, override),
                .middleware_strategy = override.middleware_strategy orelse self._config.middleware_strategy,
            };
        }
    };
}

fn getRoute(comptime A: type, root: *const Part(A), url: []const u8, params: *Params) ?A {
    if (url.len == 0 or (url.len == 1 and url[0] == '/')) {
        return root.action;
    }

    var normalized = url;
    if (normalized[0] == '/') {
        normalized = normalized[1..];
    }

    if (normalized[normalized.len - 1] == '/') {
        normalized = normalized[0 .. normalized.len - 1];
    }

    var route_part = root;
    var glob_all: ?*const Part(A) = null;
    var pos: usize = 0;
    while (pos < normalized.len) {
        const index = std.mem.indexOfScalarPos(u8, normalized, pos, '/') orelse normalized.len;
        const part = normalized[pos..index];

        // most specific "glob_all" route we find,
        // which is the one most deeply nested,
        // is the one we'll use in case there are no other matches.
        if (route_part.glob_all) {
            glob_all = route_part;
        }

        if (route_part.parts.getPtr(part)) |child| {
            route_part = child;
        } else if (route_part.param_part) |child| {
            params.addValue(part);
            route_part = child;
        } else if (route_part.glob) |child| {
            route_part = child;
        } else {
            params.len = 0;
            if (glob_all) |fallback| {
                return fallback.action;
            }
            return null;
        }
        pos = index + 1; // +1 tos skip the slash on the next iteration
    }

    if (route_part.action) |action| {
        if (route_part.param_names) |names| {
            params.addNames(names);
        } else {
            params.len = 0;
        }
        return action;
    }

    params.len = 0;
    if (glob_all) |fallback| {
        return fallback.action;
    }
    return null;
}
