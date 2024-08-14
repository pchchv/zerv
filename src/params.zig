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

    pub fn addValue(self: *Params, value: []const u8) void {
        const len = self.len;
        const values = self.values;
        if (len == values.len) {
            return;
        }
        values[len] = value;
        self.len = len + 1;
    }

    // It should be impossible for names.len != self.len at this point,
    // but assuming this is a bit dangerous since self.names is
    // reused between requests and doesn't need to leak anything,
    // so forcing a len equal to names.len is safer since names is
    // usually defined statically based on routes setup.
    pub fn addNames(self: *Params, names: [][]const u8) void {
        std.debug.assert(names.len == self.len);
        const n = self.names;
        for (names, 0..) |name, i| {
            n[i] = name;
        }
        self.len = names.len;
    }
};
