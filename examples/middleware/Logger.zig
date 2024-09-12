// This is a sample middleware

// Generally, using a custom handler with a dispatcher method provides the
// most flexibility and should be the first approach
// (see dispatcher.zig for an example).

// Middleware provides an alternative way
// to manage request/response and is well suited if different middleware
// (or middleware configurations)
// are needed for different routes.

// Must defined a pub config structure,
// even if it's empty.
pub const Config = struct {
    query: bool,
};
