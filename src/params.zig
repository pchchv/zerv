const std = @import("std");

const Allocator = std.mem.Allocator;

/// Params is similar to KeyValue with two important differences:
/// 1 - There is no need to normalize (i.e. lowercase)
///   the names because they are statically defined in the code,
///   and presumably if a parameter is called “id”,
///   the developer will also fetch it as “id”.
/// 2 - This is filled in from Router,
///   and the way Router works is that it knows the values before it knows the names.
///   The addValue and addNames methods reflect how Router uses this.
pub const Params = struct {
    len: usize,
    names: [][]const u8,
    values: [][]const u8,

    pub fn init(allocator: Allocator, max: usize) !Params {
        const names = try allocator.alloc([]const u8, max);
        const values = try allocator.alloc([]const u8, max);
        return .{
            .len = 0,
            .names = names,
            .values = values,
        };
    }

    pub fn deinit(self: *Params, allocator: Allocator) void {
        allocator.free(self.names);
        allocator.free(self.values);
    }
};
