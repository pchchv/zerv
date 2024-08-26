const std = @import("std");

const zerv = @import("zerv.zig");

const Params = @import("params.zig").Params;

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

pub fn Config(comptime Handler: type, comptime Action: type) type {
    const Dispatcher = zerv.Dispatcher(Handler, Action);
    return struct {
        handler: ?Handler = null,
        dispatcher: ?Dispatcher = null,
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
    return struct {
        _aa: Allocator,
        _prefix: []const u8,
        _router: *Router(Handler, Action),
        _config: Config(Handler, Action),

        const Self = @This();

        fn init(router: *Router(Handler, Action), prefix: []const u8, config: Config(Handler, Action)) Self {
            return .{
                ._prefix = prefix,
                ._router = router,
                ._config = config,
                ._aa = router._arena.allocator(),
            };
        }

        pub fn get(self: *Self, path: []const u8, action: Action) void {
            self.getC(path, action, self._config);
        }

        pub fn getC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.getC(self.createPath(path), action, config);
        }

        pub fn tryGet(self: *Self, path: []const u8, action: Action) !void {
            return self.tryGetC(path, action, self._config);
        }

        pub fn tryGetC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryGetC(self.tryCreatePath(path), action, config);
        }

        pub fn put(self: *Self, path: []const u8, action: Action) void {
            self.putC(path, action, self._config);
        }

        pub fn putC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.putC(self.createPath(path), action, config);
        }

        pub fn tryPut(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPutC(path, action, self._config);
        }

        pub fn tryPutC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryPutC(self.tryCreatePath(path), action, config);
        }

        pub fn post(self: *Self, path: []const u8, action: Action) void {
            self.postC(path, action, self._config);
        }

        pub fn postC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.postC(self.createPath(path), action, config);
        }

        pub fn tryPost(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPostC(path, action, self._config);
        }

        pub fn tryPostC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryPostC(self.tryCreatePath(path), action, config);
        }

        pub fn patch(self: *Self, path: []const u8, action: Action) void {
            self.patchC(path, action, self._config);
        }

        pub fn patchC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.patchC(self.createPath(path), action, config);
        }

        pub fn tryPatch(self: *Self, path: []const u8, action: Action) !void {
            return self.tryPatchC(path, action, self._config);
        }

        pub fn tryPatchC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryPatchC(self.tryCreatePath(path), action, config);
        }

        pub fn head(self: *Self, path: []const u8, action: Action) void {
            self.headC(path, action, self._config);
        }

        pub fn headC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.headC(self.createPath(path), action, config);
        }

        pub fn tryHead(self: *Self, path: []const u8, action: Action) !void {
            return self.tryHeadC(path, action, self._config);
        }

        pub fn tryHeadC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryHeadC(self.tryCreatePath(path), action, config);
        }

        pub fn trace(self: *Self, path: []const u8, action: Action) void {
            self.patchC(path, action, self._config);
        }

        pub fn traceC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.patchC(self.createPath(path), action, config);
        }

        pub fn tryTrace(self: *Self, path: []const u8, action: Action) !void {
            return self.tryTraceC(path, action, self._config);
        }

        pub fn tryTraceC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryTraceC(self.tryCreatePath(path), action, config);
        }

        pub fn delete(self: *Self, path: []const u8, action: Action) void {
            self.deleteC(path, action, self._config);
        }

        pub fn deleteC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) void {
            self._router.deleteC(self.createPath(path), action, config);
        }

        pub fn tryDelete(self: *Self, path: []const u8, action: Action) !void {
            return self.tryDeleteC(path, action, self._config);
        }

        pub fn tryDeleteC(self: *Self, path: []const u8, action: Action, config: Config(Handler, Action)) !void {
            return self._router.tryDeleteC(self.tryCreatePath(path), action, config);
        }
    };
}

fn addRoute(comptime A: type, allocator: Allocator, root: *Part(A), url: []const u8, action: A) !void {
    if (url.len == 0 or (url.len == 1 and url[0] == '/')) {
        root.action = action;
        return;
    }

    var normalized = url;
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
                const child = try allocator.create(Part(A));
                child.clear(allocator);
                route_part.param_part = child;
                route_part = child;
            }
        } else if (part.len == 1 and part[0] == '*') {
            // if this route_part didn't already have an action,
            // then this glob also includes it
            if (route_part.action == null) {
                route_part.action = action;
            }

            if (route_part.glob) |child| {
                route_part = child;
            } else {
                const child = try allocator.create(Part(A));
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

    // if the route ended with a '*' (importantly, as opposed to a '*/')
    // then this is a "glob all" route will.
    // Important, use "url" and not "normalized" since normalized stripped out the trailing / (if any),
    // which is important here
    route_part.glob_all = url[url.len - 1] == '*';

    route_part.action = action;
}

fn getRoute(comptime A: type, root: Part(A), url: []const u8, params: *Params) ?A {
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

    var r = root;
    var pos: usize = 0;
    var route_part = &r;
    var glob_all: ?*Part(A) = null;
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
