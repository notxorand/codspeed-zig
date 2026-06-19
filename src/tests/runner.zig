const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var has_failures = false;
    const stdout = std.Io.File.stdout();
    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};

        const name = extractName(t);
        const result = t.func();
        if (result) |_| {
            var msg_buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "[SUCCESS] {s}\n", .{name});
            try stdout.writeStreamingAll(io, msg);
        } else |err| switch (err) {
            error.SkipZigTest => {
                var msg_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&msg_buf, "[SKIP] {s}\n", .{name});
                try stdout.writeStreamingAll(io, msg);
            },
            else => {
                has_failures = true;
                var msg_buf: [512]u8 = undefined;
                const msg = try std.fmt.bufPrint(&msg_buf, "[FAIL] {s}: {}\n", .{ t.name, err });
                try stdout.writeStreamingAll(io, msg);
            },
        }

        if (std.testing.allocator_instance.deinit() == .leak) {
            has_failures = true;
            var msg_buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "{s} leaked memory\n", .{name});
            try stdout.writeStreamingAll(io, msg);
        }
    }
    if (has_failures) std.process.exit(1);
}

fn extractName(t: std.builtin.TestFn) []const u8 {
    const marker = std.mem.lastIndexOf(u8, t.name, ".test.") orelse return t.name;
    return t.name[marker + 6 ..];
}
