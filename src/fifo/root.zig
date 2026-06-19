const builtin = @import("builtin");

const shared = @import("../shared.zig");
pub const Command = shared.Command;

const impl = switch (builtin.os.tag) {
    .linux, .macos => @import("posix.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("unsupported OS for fifo backend"),
};

pub const Pipe = impl.Pipe;
pub const sendCmd = impl.sendCmd;
pub const sendVersion = impl.sendVersion;

test {
    _ = impl;
}
