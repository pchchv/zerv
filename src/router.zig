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

    const P = Part(DispatchableAction);
    const RC = RouteConfig(Handler, Action);

    return struct {
        _allocator: Allocator,
        _get: P,
        _put: P,
        _post: P,
        _head: P,
        _patch: P,
        _trace: P,
        _delete: P,
        _options: P,
        handler: Handler,
        dispatcher: Dispatcher,
        middlewares: []const zerv.Middleware(Handler),

        const Self = @This();

        pub fn init(allocator: Allocator, dispatcher: Dispatcher, handler: Handler) !Self {
            return .{
                .handler = handler,
                ._allocator = allocator,
                .dispatcher = dispatcher,
                .middlewares = &.{},
                ._get = try P.init(allocator),
                ._head = try P.init(allocator),
                ._post = try P.init(allocator),
                ._put = try P.init(allocator),
                ._patch = try P.init(allocator),
                ._trace = try P.init(allocator),
                ._delete = try P.init(allocator),
                ._options = try P.init(allocator),
            };
        }

        pub fn group(self: *Self, prefix: []const u8, config: RC) Group(Handler, Action) {
            return Group(Handler, Action).init(self, prefix, config);
        }

        pub fn route(self: *Self, method: zerv.Method, url: []const u8, params: *Params) ?DispatchableAction {
            return switch (method) {
                zerv.Method.GET => getRoute(DispatchableAction, &self._get, url, params),
                zerv.Method.POST => getRoute(DispatchableAction, &self._post, url, params),
                zerv.Method.PUT => getRoute(DispatchableAction, &self._put, url, params),
                zerv.Method.DELETE => getRoute(DispatchableAction, &self._delete, url, params),
                zerv.Method.PATCH => getRoute(DispatchableAction, &self._patch, url, params),
                zerv.Method.HEAD => getRoute(DispatchableAction, &self._head, url, params),
                zerv.Method.OPTIONS => getRoute(DispatchableAction, &self._options, url, params),
            };
        }

        pub fn get(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryGet(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryGet(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._get, path, action, config);
        }

        pub fn put(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryPut(path, action, config) catch @panic("failed to create route");
        }

        pub fn tryPut(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._put, path, action, config);
        }

        pub fn post(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryPost(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryPost(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._post, path, action, config);
        }

        pub fn head(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryHead(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryHead(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._head, path, action, config);
        }

        pub fn patch(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryPatch(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryPatch(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._patch, path, action, config);
        }

        pub fn trace(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryTrace(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryTrace(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._trace, path, action, config);
        }

        pub fn delete(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryDelete(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryDelete(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._delete, path, action, config);
        }

        pub fn options(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryOptions(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryOptions(self: *Self, path: []const u8, action: Action, config: RC) !void {
            return self.addRoute(&self._options, path, action, config);
        }

        pub fn all(self: *Self, path: []const u8, action: Action, config: RC) void {
            self.tryAll(path, action, config) catch @panic("failed to create route");
        }
        pub fn tryAll(self: *Self, path: []const u8, action: Action, config: RC) !void {
            try self.tryGet(path, action, config);
            try self.tryPut(path, action, config);
            try self.tryPost(path, action, config);
            try self.tryHead(path, action, config);
            try self.tryPatch(path, action, config);
            try self.tryTrace(path, action, config);
            try self.tryDelete(path, action, config);
            try self.tryOptions(path, action, config);
        }

        fn addRoute(self: *Self, root: *P, path: []const u8, action: Action, config: RC) !void {
            const da = DispatchableAction{
                .action = action,
                .data = config.data,
                .handler = config.handler orelse self.handler,
                .dispatcher = config.dispatcher orelse self.dispatcher,
                .middlewares = try self.mergeMiddleware(self.middlewares, config),
            };

            if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
                root.action = da;
                return;
            }

            const allocator = self._allocator;

            var normalized = path;
            if (normalized[0] == '/') {
                normalized = normalized[1..];
            }
            if (normalized[normalized.len - 1] == '/') {
                normalized = normalized[0 .. normalized.len - 1];
            }

            var param_name_collector = std.ArrayList([]const u8).init(allocator);
            defer param_name_collector.deinit();

            var route_part = root;
            var it = std.mem.splitScalar(u8, normalized, '/');
            while (it.next()) |part| {
                if (part[0] == ':') {
                    try param_name_collector.append(part[1..]);
                    if (route_part.param_part) |child| {
                        route_part = child;
                    } else {
                        const child = try allocator.create(P);
                        child.clear(allocator);
                        route_part.param_part = child;
                        route_part = child;
                    }
                } else if (part.len == 1 and part[0] == '*') {
                    // if this route_part didn't already have an action, then this glob also
                    // includes it
                    if (route_part.action == null) {
                        route_part.action = da;
                    }

                    if (route_part.glob) |child| {
                        route_part = child;
                    } else {
                        const child = try allocator.create(P);
                        child.clear(allocator);
                        route_part.glob = child;
                        route_part = child;
                    }
                } else {
                    const gop = try route_part.parts.getOrPut(part);
                    if (gop.found_existing) {
                        route_part = gop.value_ptr;
                    } else {
                        route_part = gop.value_ptr;
                        route_part.clear(allocator);
                    }
                }
            }

            const param_name_count = param_name_collector.items.len;
            if (param_name_count > 0) {
                const param_names = try allocator.alloc([]const u8, param_name_count);
                for (param_name_collector.items, 0..) |name, i| {
                    param_names[i] = name;
                }
                route_part.param_names = param_names;
            }

            // if the route ended with a '*' (importantly, as opposed to a '*/') then
            // this is a "glob all" route will. Important, use "url" and not "normalized"
            // since normalized stripped out the trailing / (if any), which is important
            // here
            route_part.glob_all = path[path.len - 1] == '*';

            route_part.action = da;
        }

        fn mergeMiddleware(self: *Self, parent_middlewares: []const zerv.Middleware(Handler), config: RC) ![]const zerv.Middleware(Handler) {
            const route_middlewares = config.middlewares orelse return parent_middlewares;

            const strategy = config.middleware_strategy orelse .append;
            if (strategy == .replace or parent_middlewares.len == 0) {
                return route_middlewares;
            }

            // allocator is an arena
            const merged = try self._allocator.alloc(zerv.Middleware(Handler), route_middlewares.len + parent_middlewares.len);
            @memcpy(merged[0..parent_middlewares.len], parent_middlewares);
            @memcpy(merged[parent_middlewares.len..], route_middlewares);
            return merged;
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
