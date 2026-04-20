const std = @import("std");

// Adaptation of [`std.Thread.sleep`](https://ziglang.org/documentation/0.14.0/std/#std.Thread.sleep)
// to ensure that the C code is architecture-independent. The stdlib implementation uses inline syscalls,
// which only works on a single architecture and is not portable.
pub fn sleep(nanoseconds: u64) void {
    const sec_type = @typeInfo(std.posix.timespec).@"struct".fields[0].type;
    const nsec_type = @typeInfo(std.posix.timespec).@"struct".fields[1].type;

    var req: std.posix.timespec = .{
        .sec = std.math.cast(sec_type, nanoseconds / std.time.ns_per_s) orelse std.math.maxInt(sec_type),
        .nsec = std.math.cast(nsec_type, nanoseconds % std.time.ns_per_s) orelse std.math.maxInt(nsec_type),
    };

    while (true) {
        switch (std.posix.errno(std.posix.system.nanosleep(&req, &req))) {
            .INTR => continue,
            else => return,
        }
    }
}

test "sleep for at least 1 second" {
    const start = std.Io.Clock.awake.now(std.testing.io);
    sleep(1 * std.time.ns_per_s);

    const elapsed_ns: u64 = @intCast(start.untilNow(std.testing.io, .awake).toNanoseconds());
    const elapsed_s = elapsed_ns / std.time.ns_per_s;

    std.debug.assert(elapsed_s >= 1);
    std.debug.assert(elapsed_s < 2);
}
