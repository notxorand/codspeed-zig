const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{});

        const name = extractName(t);
        const result = t.func();

        std.testing.io_instance.deinit();

        var buf: [512]u8 = undefined;
        const msg = if (result) |_|
            try std.fmt.bufPrint(&buf, "[SUCCESS] {s}\n", .{name})
        else |err|
            try std.fmt.bufPrint(&buf, "[FAIL] {s}: {}\n", .{ t.name, err });

        try stdout.writeStreamingAll(io, msg);

        if (std.testing.allocator_instance.deinit() == .leak) {
            const leak_msg = try std.fmt.bufPrint(&buf, "{s} leaked memory\n", .{name});
            try stdout.writeStreamingAll(io, leak_msg);
        }
    }
}

fn extractName(t: std.builtin.TestFn) []const u8 {
    const marker = std.mem.lastIndexOf(u8, t.name, ".test.") orelse return t.name;
    return t.name[marker + 6 ..];
}
