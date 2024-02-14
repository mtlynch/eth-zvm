const std = @import("std");
const time = std.time;
const Timer = std.time.Timer;

// Example bytecode we want to execute.
//
// // Set the stat
// PUSH1 1
// PUSH1 0
// MSTORE

// // Example
// PUSH1 1
// PUSH1 31
// RETURN
//
// Should end with
// Return value: 0x01
// Stack: empty
// Storage: empty
// Memory: 0x01

// mstore offsets
// 0:  00000000000000000000000000000000000000000000000000000000000000ff
// 1:  0000000000000000000000000000000000000000000000000000000000000000ff00000000000000000000000000000000000000000000000000000000000000
// 2:  000000000000000000000000000000000000000000000000000000000000000000ff000000000000000000000000000000000000000000000000000000000000
// 32: 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff

const OpCode = enum(u8) {
    PUSH1 = 0x60,
    PUSH32 = 0x7f,
    MSTORE = 0x52,
    RETURN = 0xf3,
    _,
};

const BytecodeReader = struct {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(OpCode.PUSH1), 0x01,
        @intFromEnum(OpCode.PUSH1), 0x00,
        @intFromEnum(OpCode.MSTORE),
        @intFromEnum(OpCode.PUSH1), 0x01,
        @intFromEnum(OpCode.PUSH1), 0x1f,
        @intFromEnum(OpCode.RETURN),
    };
    // zig fmt: on

    bytes: []const u8 = &bytecode,
    index: u32 = 0,

    pub fn nextByte(self: *BytecodeReader) u8 {
        // TODO: Handle out of bounds error.
        const b = self.bytes[self.index];
        self.index += 1;
        return b;
    }

    pub fn done(self: BytecodeReader) bool {
        return self.index >= self.bytes.len;
    }
};

const VMError = error{
    NotImplemented,
};

const VM = struct {
    stack: std.ArrayList(u8) = undefined,
    memory: std.ArrayList(u32) = undefined,
    returnValue: u8 = undefined,
    verbose: bool = false,
    gasConsumed: u64 = 0,

    pub fn init(self: *VM, allocator: std.mem.Allocator, verbose: bool) void {
        self.stack = std.ArrayList(u8).init(allocator);
        self.memory = std.ArrayList(u32).init(allocator);
        self.verbose = verbose;
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit();
        self.memory.deinit();
    }

    pub fn run(self: *VM, reader: *BytecodeReader) !void {
        while (!reader.done()) {
            try self.nextInstruction(reader);
        }
    }

    pub fn nextInstruction(self: *VM, reader: *BytecodeReader) !void {
        const op: OpCode = @enumFromInt(reader.nextByte());
        switch (op) {
            OpCode.PUSH1 => {
                self.printVerbose("Handle {s}\n", .{@tagName(op)});
                const b = reader.nextByte();
                self.printVerbose("Pushed {d} onto stack\n", .{b});
                try self.stack.append(b);
                self.gasConsumed += 3;
            },
            OpCode.PUSH32 => {
                self.printVerbose("Handle {s}\n", .{@tagName(op)});
                return VMError.NotImplemented;
            },
            OpCode.MSTORE => {
                const offset = self.stack.pop();
                const value = self.stack.pop();
                self.printVerbose("Handle {s} offset={d}, value={d}\n", .{ @tagName(op), offset, value });
                if (offset != 0) {
                    return VMError.NotImplemented;
                }
                self.printVerbose("Set memory to {d}\n", .{value});

                const oldState = ((self.memory.items.len << 2) / 512) + (3 * self.memory.items.len);
                try self.memory.append(value);
                const newState = ((self.memory.items.len << 2) / 512) + (3 * self.memory.items.len);
                self.gasConsumed += 3;
                self.gasConsumed += @as(u64, newState - oldState);
            },
            OpCode.RETURN => {
                const offset = self.stack.pop();
                const size = self.stack.pop();
                self.printVerbose("Handle {s} offset={d}, size={d}\n", .{ @tagName(op), offset, size });
                if (size != 1) {
                    return VMError.NotImplemented;
                }
                if (offset != 31) {
                    return VMError.NotImplemented;
                }
                const val = self.memory.getLast();
                const shrunk: u8 = @as(u8, @truncate(val));
                self.returnValue = shrunk;
                self.printVerbose("RETURN {d}\n", .{shrunk});
            },
            else => {
                self.printVerbose("Not yet handling opcode {d}\n", .{op});
                return VMError.NotImplemented;
            },
        }
    }

    fn printVerbose(self: VM, comptime fmt: []const u8, args: anytype) void {
        if (self.verbose) {
            std.debug.print(fmt, args);
        }
    }
};

pub fn main() !void {
    const verboseMode = ((std.os.argv.len > 1) and std.mem.eql(u8, std.mem.span(std.os.argv[1]), "-v"));

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var bcReader = BytecodeReader{};

    var evm = VM{};
    evm.init(allocator, verboseMode);
    defer evm.deinit();

    var timer = try Timer.start();
    const start = timer.lap();
    try evm.run(&bcReader);
    const end = timer.read();
    const elapsed_micros = @as(f64, @floatFromInt(end - start)) / time.ns_per_us;
    std.debug.print("EVM gas used:    {}\n", .{evm.gasConsumed});
    std.debug.print("execution time:  {d:.1}µs\n", .{elapsed_micros});
    std.debug.print("0x{x:0>2}\n", .{evm.returnValue});
}

test "simple test" {
    // TODO
    // try std.testing.expectEqual(@as(i32, 42), list.pop());
}
