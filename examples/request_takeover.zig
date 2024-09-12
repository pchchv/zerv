// This example uses the Handler's "handle" function to
// completely takeover request processing from zerv.

const zerv = @import("zerv");

const Handler = struct {
    pub fn handle(_: *Handler, _: *zerv.Request, res: *zerv.Response) void {
        res.body =
            \\ If defined, the "handle" function is called early in zerv' request
            \\ processing. Routing, middlewares, not found and error handling are all skipped.
            \\ This is an advanced option and is used by frameworks like JetZig to provide
            \\ their own flavor and enhancement ontop of zerv.
            \\ If you define this, the special "dispatch", "notFound" and "uncaughtError"
            \\ functions have no meaning as far as zerv is concerned.
        ;
    }
};
