pub const Buffer = struct {
    data: []u8,
    type: Type,

    const Type = enum {
        arena,
        static,
        pooled,
        dynamic,
    };
};
