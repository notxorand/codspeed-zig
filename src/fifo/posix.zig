const std = @import("std");
const Allocator = std.mem.Allocator;

const bincode = @import("../bincode.zig");
const shared = @import("../shared.zig");
pub const Command = shared.Command;

const Path = []const u8;
extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

/// Wait until `fd` is readable, returning `error.AckTimeout` if no data
/// arrives within `timeout_ns`. Used to gate blocking reads so we never
/// consume bytes from a partially-written FIFO frame and lose framing.
fn waitReadable(fd: std.posix.fd_t, timeout_ns: u64) !void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ms_total = timeout_ns / std.time.ns_per_ms;
    const timeout_ms: i32 = if (ms_total > std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(ms_total);
    const ready = std.posix.poll(&pfd, timeout_ms) catch return error.AckTimeout;
    if (ready == 0) return error.AckTimeout;
}

pub const Pipe = struct {
    pub const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        allocator: Allocator,
        buffer: std.ArrayList(u8),

        pub fn init(file: std.Io.File, io: std.Io, allocator: Allocator) Reader {
            var buffer: std.ArrayList(u8) = .empty;
            buffer.ensureTotalCapacity(allocator, 1024) catch {};
            return .{
                .file = file,
                .io = io,
                .allocator = allocator,
                .buffer = buffer,
            };
        }

        pub fn read(self: *Reader, buffer: []u8) !usize {
            return self.file.readStreaming(self.io, &.{buffer});
        }

        pub fn readAll(self: *Reader, buffer: []u8) !usize {
            var total: usize = 0;
            while (total < buffer.len) {
                const n = try self.file.readStreaming(self.io, &.{buffer[total..]});
                if (n == 0) break;
                total += n;
            }
            return total;
        }

        // IMPORTANT: Caller is responsible for freeing the returned command.
        pub fn recvCmd(self: *Reader) !Command {
            // First read the length (u32 = 4 bytes)
            var len_buffer: [4]u8 = undefined;
            const len_read = try self.readAll(&len_buffer);
            if (len_read < 4) {
                return error.UnexpectedEof;
            }
            const message_len = std.mem.readInt(u32, &len_buffer, std.builtin.Endian.little);

            // Resize buffer to fit message (only allocates if growing)
            try self.buffer.resize(self.allocator, message_len);

            const msg_read = try self.readAll(self.buffer.items);
            if (msg_read < message_len) {
                return error.UnexpectedEof;
            }

            var reader: std.Io.Reader = .fixed(self.buffer.items);
            return try bincode.deserializeAlloc(&reader, self.allocator, Command);
        }

        pub fn waitForResponse(self: *Reader, timeout_ns: ?u64) !Command {
            const timeout = timeout_ns orelse std.time.ns_per_s * 1; // Default 1 second timeout
            try waitReadable(self.file.handle, timeout);
            return self.recvCmd();
        }

        pub fn waitForAck(self: *Reader, timeout_ns: ?u64) !void {
            const response = try self.waitForResponse(timeout_ns);
            defer response.deinit(self.allocator);

            switch (response) {
                .Ack => return,
                .Err => return error.UnexpectedError,
                else => {
                    const logger = @import("../logger.zig");
                    logger.debug("waitForAck received unexpected response: {}\n", .{response});
                    return error.UnexpectedResponse;
                },
            }
        }

        pub fn deinit(self: *Reader) void {
            // Drain any pending data from the FIFO before closing to prevent
            // stale messages from being read by subsequent connections.
            // This is crucial when multiple instrument types probe the same FIFO
            // (e.g., AnalysisInstrument fails, then WalltimeInstrument tries).
            // The fd is blocking, so poll with timeout=0 to consume only what's
            // currently available without ever blocking on an empty FIFO.
            var dummy_buffer: [4096]u8 = undefined;
            while (true) {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = self.file.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, 0) catch break;
                if (ready == 0) break;
                const bytes_read = self.read(&dummy_buffer) catch break;
                if (bytes_read == 0) break;
            }

            self.buffer.deinit(self.allocator);
            self.file.close(self.io);
        }
    };

    pub const Writer = struct {
        file: std.Io.File,
        io: std.Io,
        allocator: Allocator,
        buffer: std.ArrayList(u8),

        pub fn init(file: std.Io.File, io: std.Io, allocator: Allocator) Writer {
            var buffer: std.ArrayList(u8) = .empty;
            buffer.ensureTotalCapacity(allocator, 1024) catch {};
            return .{
                .file = file,
                .io = io,
                .allocator = allocator,
                .buffer = buffer,
            };
        }

        pub fn write(self: *Writer, buffer: []const u8) !usize {
            return self.file.writeStreaming(self.io, &.{buffer});
        }

        pub fn writeAll(self: *Writer, buffer: []const u8) !void {
            return self.file.writeStreamingAll(self.io, buffer);
        }

        pub fn sendCmd(self: *Writer, cmd: Command) !void {
            // Clear buffer but keep allocated capacity
            self.buffer.clearRetainingCapacity();

            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try bincode.serialize(&aw.writer, cmd);
            const serialized = aw.written();

            try self.file.writeStreamingAll(self.io, std.mem.asBytes(&@as(u32, @intCast(serialized.len))));
            try self.file.writeStreamingAll(self.io, serialized);
        }

        pub fn deinit(self: *Writer) void {
            self.buffer.deinit(self.allocator);
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

    fn openPipe(io: std.Io, path: []const u8) !std.Io.File {
        try std.Io.Dir.accessAbsolute(io, path, .{ .read = true, .write = true });
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        return std.Io.File{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
    }

    pub fn openRead(allocator: Allocator, io: std.Io, path: []const u8) !Reader {
        const file = try openPipe(io, path);
        return Reader.init(file, io, allocator);
    }

    pub fn openWrite(allocator: Allocator, io: std.Io, path: []const u8) !Writer {
        const file = try openPipe(io, path);
        return Writer.init(file, io, allocator);
    }
};

pub fn sendCmd(allocator: Allocator, io: std.Io, cmd: Command) !void {
    var writer = try Pipe.openWrite(allocator, io, shared.RUNNER_CTL_FIFO);
    defer writer.deinit();
    try writer.sendCmd(cmd);

    var reader = try Pipe.openRead(allocator, io, shared.RUNNER_ACK_FIFO);
    defer reader.deinit();
    try reader.waitForAck(null);
}

pub fn sendVersion(allocator: Allocator, io: std.Io, protocol_version: u64) !void {
    const cmd = Command{ .SetVersion = protocol_version };
    try sendCmd(allocator, io, cmd);
}

test "fail if doesn't exist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const nonexistent_path = "/tmp/nonexistent_pipe_test.fifo";

    // Ensure it doesn't exist
    std.Io.Dir.deleteFileAbsolute(io, nonexistent_path) catch {};

    // Attempt to open for reading should fail
    const reader_result = Pipe.openRead(allocator, io, nonexistent_path);
    try std.testing.expectError(error.FileNotFound, reader_result);

    // Attempt to open for writing should fail
    const writer_result = Pipe.openWrite(allocator, io, nonexistent_path);
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

    try Pipe.create(io, test_path);

    var reader = try Pipe.openRead(allocator, io, test_path);
    defer reader.deinit();

    var writer = try Pipe.openWrite(allocator, io, test_path);
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

    try Pipe.create(io, test_path);

    var reader = try Pipe.openRead(allocator, io, test_path);
    defer reader.deinit();

    var writer = try Pipe.openWrite(allocator, io, test_path);
    defer writer.deinit();

    try writer.sendCmd(Command.StartBenchmark);
    const cmd = try reader.recvCmd();
    defer cmd.deinit(writer.allocator);

    try std.testing.expectEqual(Command.StartBenchmark, cmd);
}

test "unix pipe send without ack" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_path = "/tmp/test_no_ack.fifo";

    try Pipe.create(io, test_path);

    // Open both reader and writer so they don't block on open
    var reader = try Pipe.openRead(allocator, io, test_path);
    defer reader.deinit();

    var writer = try Pipe.openWrite(allocator, io, test_path);
    defer writer.deinit();

    // Writer doesn't send anything, so waitForResponse should timeout
    const result = reader.waitForResponse(std.time.ns_per_ms * 100);
    try std.testing.expectError(error.AckTimeout, result);
}

test "unix pipe prevents stale messages between connections" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_path = "/tmp/test_stale_messages.fifo";

    try Pipe.create(io, test_path);

    // Keep writer open throughout to maintain the FIFO
    var writer = try Pipe.openWrite(allocator, io, test_path);
    defer writer.deinit();

    // STEP 1: Simulate first connection
    {
        var first_reader = try Pipe.openRead(allocator, io, test_path);

        // Send and successfully read first command
        try writer.sendCmd(Command.StartBenchmark);
        const cmd1 = try first_reader.recvCmd();
        defer cmd1.deinit(allocator);
        try std.testing.expect(cmd1.equal(Command.StartBenchmark));

        // Send second command but DON'T read it
        try writer.sendCmd(Command.StopBenchmark);

        // Close first reader WITHOUT reading the second command
        // This should drain the unread StopBenchmark message
        first_reader.deinit();
    }

    // STEP 2: Simulate second connection
    {
        var second_reader = try Pipe.openRead(allocator, io, test_path);
        defer second_reader.deinit();

        // Send fresh command
        try writer.sendCmd(Command.Ack);

        // This should read the fresh Ack, NOT the stale StopBenchmark
        const cmd2 = try second_reader.recvCmd();
        defer cmd2.deinit(allocator);

        // CRITICAL ASSERTION: We should receive the fresh Ack
        // Without the drain logic, this would fail with StopBenchmark
        try std.testing.expect(cmd2.equal(Command.Ack));
    }
}
