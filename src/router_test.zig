const zerv = @import("zerv.zig");

const Request = @import("request.zig");
const Response = @import("response.zig");

fn testDispatcher1(_: zerv.Action(void), _: *Request, _: *Response) anyerror!void {}
