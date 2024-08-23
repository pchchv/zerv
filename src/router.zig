const std = @import("std");

const zerv = @import("zerv.zig");

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
    };
}
