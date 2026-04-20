const std = @import("std");
const Allocator = std.mem.Allocator;

const bincode = @import("bincode.zig");
const shared = @import("shared.zig");
pub const Command = shared.Command;

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

pub const UnixPipe = struct {
    pub const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        allocator: Allocator,

        pub fn init(file: std.Io.File, io: std.Io, allocator: Allocator) Reader {
            return .{
                .file = file,
                .io = io,
                .allocator = allocator,
            };
        }

        pub fn read(self: *Reader, buffer: []u8) !usize {
            return self.file.readStreaming(self.io, buffer);
        }

        pub fn readAll(self: *Reader, buffer: []u8) !usize {
            var index: usize = 0;
            while (index < buffer.len) {
                const amt = try self.file.readStreaming(self.io, &.{buffer[index..]});
                if (amt == 0) break;
                index += amt;
            }
            return index;
        }

        // IMPORTANT: Caller is responsible for freeing the returned command.
        pub fn recvCmd(self: *Reader) !Command {
            // First read the length (u32 = 4 bytes)
            var len_buffer: [4]u8 = undefined;
            _ = try self.readAll(&len_buffer);
            const message_len = std.mem.readInt(u32, &len_buffer, std.builtin.Endian.little);

            // Read the message
            const buffer = try self.allocator.alloc(u8, message_len);
            defer self.allocator.free(buffer);

            while (true) {
                _ = self.readAll(buffer) catch {
                    continue;
                };
                break;
            }

            var reader: std.Io.Reader = .fixed(buffer);
            return try bincode.deserializeAlloc(&reader, self.allocator, Command);
        }

        pub fn waitForResponse(self: *Reader, timeout_ns: ?u64) !Command {
            const start = std.Io.Clock.awake.now(self.io);
            const timeout = timeout_ns orelse std.time.ns_per_s * 5; // Default 5 second timeout

            while (true) {
                const elapsed: u64 = @intCast(start.untilNow(self.io, .awake).toNanoseconds());
                if (elapsed > timeout) {
                    return error.AckTimeout;
                }

                const cmd = self.recvCmd() catch {
                    const utils = @import("utils.zig");
                    utils.sleep(std.time.ns_per_ms * 10);
                    continue;
                };

                return cmd;
            }
        }

        pub fn waitForAck(self: *Reader, timeout_ns: ?u64) !void {
            const response = try self.waitForResponse(timeout_ns);
            defer response.deinit(self.allocator);

            if (response == Command.Ack) {
                return;
            } else if (response == Command.Err) {
                return error.UnexpectedError;
            } else {
                return error.UnexpectedResponse;
            }
        }

        pub fn deinit(self: *Reader) void {
            self.file.close(self.io);
        }
    };

    pub const Writer = struct {
        file: std.Io.File,
        io: std.Io,
        allocator: Allocator,

        pub fn init(file: std.Io.File, io: std.Io, allocator: Allocator) Writer {
            return .{
                .file = file,
                .io = io,
                .allocator = allocator,
            };
        }

        pub fn write(self: *Writer, buffer: []const u8) !usize {
            return self.file.writeStreaming(self.io, buffer);
        }

        pub fn writeAll(self: *Writer, buffer: []const u8) !void {
            return self.file.writeStreamingAll(self.io, buffer);
        }

        pub fn sendCmd(self: *Writer, cmd: Command) !void {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();

            try bincode.serialize(&aw.writer, cmd);

            const bytes = aw.writer.buffer[0..aw.writer.end];
            try self.writeAll(std.mem.asBytes(&@as(u32, @intCast(bytes.len))));
            try self.writeAll(bytes);
        }

        pub fn deinit(self: *Writer) void {
            self.file.close(self.io);
        }
    };

    /// Create a new named pipe at the given path
    pub fn create(io: std.Io, path: [*:0]const u8) !void {
        // Remove the previous FIFO (if it exists)
        std.Io.Dir.deleteFileAbsolute(io, std.mem.span(path)) catch {};

        if (mkfifo(path, 0o700) != 0) {
            return error.FifoCreationFailed;
        }
    }

    pub fn openRead(allocator: Allocator, io: std.Io, path: []const u8) !Reader {
        try std.Io.Dir.accessAbsolute(io, path, .{ .read = true, .write = true });
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
        return Reader.init(file, io, allocator);
    }

    pub fn openWrite(allocator: Allocator, io: std.Io, path: []const u8) !Writer {
        try std.Io.Dir.accessAbsolute(io, path, .{ .read = true, .write = true });
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
        return Writer.init(file, io, allocator);
    }
};

pub const BenchGuard = struct {
    ctl_writer: UnixPipe.Writer,
    ack_reader: UnixPipe.Reader,
    allocator: Allocator,

    pub fn init(allocator: Allocator, io: std.Io, ctl_fifo_path: []const u8, ack_fifo_path: []const u8) !*BenchGuard {
        var self = try allocator.create(BenchGuard);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.ctl_writer = try UnixPipe.openWrite(allocator, io, ctl_fifo_path);
        self.ack_reader = try UnixPipe.openRead(allocator, io, ack_fifo_path);

        try self.sendCmd(Command.StartBenchmark);
        return self;
    }

    pub fn initWithRunnerFifo(allocator: Allocator, io: std.Io) !*BenchGuard {
        return try BenchGuard.init(allocator, io, shared.RUNNER_CTL_FIFO, shared.RUNNER_ACK_FIFO);
    }

    pub fn deinit(self: *BenchGuard) void {
        self.sendCmd(Command.StopBenchmark) catch {};
        self.ctl_writer.deinit();
        self.ack_reader.deinit();
        self.allocator.destroy(self);
    }

    fn sendCmd(self: *BenchGuard, cmd: Command) !void {
        try self.ctl_writer.sendCmd(cmd);
        try self.ack_reader.waitForAck(null);
    }
};

pub fn sendCmd(allocator: Allocator, io: std.Io, cmd: Command) !void {
    var writer = try UnixPipe.openWrite(allocator, io, shared.RUNNER_CTL_FIFO);
    defer writer.deinit();
    try writer.sendCmd(cmd);

    var reader = try UnixPipe.openRead(allocator, io, shared.RUNNER_ACK_FIFO);
    defer reader.deinit();
    try reader.waitForAck(null);
}

test "fail if doesn't exist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const nonexistent_path = "/tmp/nonexistent_pipe_test.fifo";

    // Ensure it doesn't exist
    std.Io.Dir.deleteFileAbsolute(io, nonexistent_path) catch {};

    // Attempt to open for reading should fail
    const reader_result = UnixPipe.openRead(allocator, io, nonexistent_path);
    try std.testing.expectError(error.FileNotFound, reader_result);

    // Attempt to open for writing should fail
    const writer_result = UnixPipe.openWrite(allocator, io, nonexistent_path);
    try std.testing.expectError(error.FileNotFound, writer_result);

    // Attempt to send cmd to runner fifo
    std.Io.Dir.deleteFileAbsolute(io, shared.RUNNER_ACK_FIFO) catch {};
    std.Io.Dir.deleteFileAbsolute(io, shared.RUNNER_CTL_FIFO) catch {};

    const sendcmd_result = sendCmd(allocator, io, Command.StartBenchmark);
    try std.testing.expectError(error.FileNotFound, sendcmd_result);
}

test "unix pipe write read" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_path = "/tmp/test1.fifo";

    try UnixPipe.create(io, test_path);

    var reader = try UnixPipe.openRead(allocator, io, test_path);
    defer reader.deinit();

    var writer = try UnixPipe.openWrite(allocator, io, test_path);
    defer writer.deinit();

    const message = "Hello";
    try writer.writeAll(message);

    var buffer: [5]u8 = undefined;
    _ = try reader.readAll(&buffer);

    try std.testing.expectEqualStrings(message, &buffer);
}

test "unix pipe send recv cmd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_path = "/tmp/test2.fifo";

    try UnixPipe.create(io, test_path);

    var reader = try UnixPipe.openRead(allocator, io, test_path);
    defer reader.deinit();

    var writer = try UnixPipe.openWrite(allocator, io, test_path);
    defer writer.deinit();

    try writer.sendCmd(Command.StartBenchmark);
    const cmd = try reader.recvCmd();
    defer cmd.deinit(writer.allocator);

    try std.testing.expectEqual(Command.StartBenchmark, cmd);
}
