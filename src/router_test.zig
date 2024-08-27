const zerv = @import("zerv.zig");

const Request = @import("request.zig");
const Response = @import("response.zig");

fn testDispatcher1(_: zerv.Action(void), _: *Request, _: *Response) anyerror!void {}
fn testRoute1(_: *Request, _: *Response) anyerror!void {}
fn testRoute2(_: *Request, _: *Response) anyerror!void {}
fn testRoute3(_: *Request, _: *Response) anyerror!void {}
fn testRoute4(_: *Request, _: *Response) anyerror!void {}
fn testRoute5(_: *Request, _: *Response) anyerror!void {}
fn testRoute6(_: *Request, _: *Response) anyerror!void {}
