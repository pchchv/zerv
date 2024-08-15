const build = @import("build");
const builtin = @import("builtin");

const force_blocking: bool = if (@hasDecl(build, "httpz_blocking")) build.httpz_blocking else false;

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
};

pub const ContentType = enum {
    BINARY,
    CSS,
    CSV,
    EOT,
    EVENTS,
    GIF,
    GZ,
    HTML,
    ICO,
    JPG,
    JS,
    JSON,
    OTF,
    PDF,
    PNG,
    SVG,
    TAR,
    TEXT,
    TTF,
    WASM,
    WEBP,
    WOFF,
    WOFF2,
    XML,
    UNKNOWN,
};

pub fn blockingMode() bool {
    if (force_blocking) {
        return true;
    }
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
        else => true,
    };
}
