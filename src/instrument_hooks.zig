const std = @import("std");

const environment = @import("./environment/root.zig");
const Environment = environment.Environment;
const instruments = @import("./instruments/root.zig");
const Instrument = instruments.Instrument;

pub const InstrumentHooks = struct {
    instrument: Instrument,
    environment: Environment,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return .{
            .instrument = try Instrument.init(allocator, io),
            .environment = Environment.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.instrument.deinit();
        self.environment.deinit();
    }
};
