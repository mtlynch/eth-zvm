const std = @import("std");
const stack = @import("stack.zig");

pub const OpCode = enum(u8) {
    ADD = 0x01,
    PUSH1 = 0x60,
    PUSH32 = 0x7f,
    MSTORE = 0x52,
    RETURN = 0xf3,
    _,
};

pub const VMError = error{
    NotImplemented,
    MemoryReferenceTooLarge,
};

pub const VM = struct {
    allocator: std.mem.Allocator = undefined,
    stack: stack.Stack = stack.Stack{},
    memory: std.ArrayList(u256) = undefined,
    returnValue: []u8 = undefined,
    gasConsumed: u64 = 0,

    pub fn init(self: *VM, allocator: std.mem.Allocator) void {
        self.memory = std.ArrayList(u256).init(allocator);
        self.allocator = allocator;
    }

    pub fn deinit(self: *VM) void {
        self.memory.deinit();
        self.allocator.free(self.returnValue);
    }

    pub fn run(self: *VM, reader: anytype) !void {
        while (try self.nextInstruction(reader)) {
            std.log.debug("---", .{});
        }
    }

    pub fn nextInstruction(self: *VM, reader: anytype) !bool {
        // This doesn't really matter, since the opcode is a single byte.
        const byteOrder = std.builtin.Endian.Big;

        const op: OpCode = reader.readEnum(OpCode, byteOrder) catch |err| switch (err) {
            error.EndOfStream => {
                return false;
            },
            else => {
                return err;
            },
        };
        switch (op) {
            OpCode.ADD => {
                std.log.debug("{s}", .{
                    @tagName(op),
                });
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const c = @addWithOverflow(a, b)[0];
                try self.stack.push(c);
                self.gasConsumed += 3;
                return true;
            },
            OpCode.PUSH1 => {
                const b = try reader.readByte();
                std.log.debug("{s} 0x{x:0>2}", .{ @tagName(op), b });
                try self.stack.push(b);
                self.gasConsumed += 3;
                return true;
            },
            OpCode.PUSH32 => {
                const b = try reader.readIntBig(u256);
                std.log.debug("{s} 0x{x:0>32}", .{ @tagName(op), b });
                try self.stack.push(b);
                self.gasConsumed += 3;
                return true;
            },
            OpCode.MSTORE => {
                std.log.debug("{s}", .{@tagName(op)});
                const offset = try self.stack.pop();
                const value = try self.stack.pop();
                std.log.debug("  Memory: Writing value=0x{x} to memory offset={d}", .{ value, offset });
                if (offset != 0) {
                    return VMError.NotImplemented;
                }
                std.log.debug("  Memory: 0x{x:0>32}", .{value});

                const oldState = ((self.memory.items.len << 2) / 512) + (3 * self.memory.items.len);
                try self.memory.append(value);
                const newState = ((self.memory.items.len << 2) / 512) + (3 * self.memory.items.len);
                self.gasConsumed += 3;
                self.gasConsumed += @as(u64, newState - oldState);
                return true;
            },
            OpCode.RETURN => {
                std.log.debug("{s}", .{@tagName(op)});
                const offset256 = try self.stack.pop();
                const size256 = try self.stack.pop();

                const offset = std.math.cast(u32, offset256) orelse return VMError.MemoryReferenceTooLarge;
                const size = std.math.cast(u32, size256) orelse return VMError.MemoryReferenceTooLarge;

                std.log.debug("  Memory: reading size={d} bytes from offset={d}", .{ size, offset });

                self.returnValue = try readMemory(self.allocator, self.memory.items, offset, size);
                std.log.debug("  Return value: 0x{}", .{std.fmt.fmtSliceHexLower(self.returnValue)});
                return true;
            },
            else => {
                std.log.err("Not yet handling opcode {d}", .{op});
                return VMError.NotImplemented;
            },
        }
    }
};

fn toBigEndian(x: u256) u256 {
    return std.mem.nativeTo(u256, x, std.builtin.Endian.Big);
}

fn readMemory(allocator: std.mem.Allocator, memory: []const u256, offset: u32, size: u32) ![]u8 {
    // Make a copy of memory in big-endian order.
    // TODO: We can optimize this to only copy the bytes that we want to read.
    var memoryCopy = try std.ArrayList(u256).initCapacity(allocator, memory.len);
    defer memoryCopy.deinit();
    for (0..memory.len) |i| {
        memoryCopy.insertAssumeCapacity(i, toBigEndian(memory[i]));
    }

    const mBytes = std.mem.sliceAsBytes(memoryCopy.items);

    var rBytes = try std.ArrayList(u8).initCapacity(allocator, size);
    errdefer rBytes.deinit();
    for (0..size) |i| {
        try rBytes.insert(i, mBytes[offset + i]);
    }

    return try rBytes.toOwnedSlice();
}

fn testBytecode(bytecode: []const u8, expectedReturnValue: []const u8, expectedGasConsumed: u64, expectedStack: []const u256, expectedMemory: []const u256) !void {
    const allocator = std.testing.allocator;

    var stream = std.io.fixedBufferStream(bytecode);
    var reader = stream.reader();

    var evm = VM{};
    evm.init(allocator);
    defer evm.deinit();

    try evm.run(&reader);

    try std.testing.expectEqualSlices(u8, expectedReturnValue, evm.returnValue);
    try std.testing.expectEqual(expectedGasConsumed, evm.gasConsumed);
    try std.testing.expectEqualSlices(u256, expectedStack, evm.stack.slice());
    try std.testing.expectEqualSlices(u256, expectedMemory, evm.memory.items);
}

test "add two bytes" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(OpCode.PUSH1), 0x03,
        @intFromEnum(OpCode.PUSH1), 0x02,
        @intFromEnum(OpCode.ADD),
    };
    // zig fmt: on

    const expectedReturnValue = [_]u8{};
    try testBytecode(&bytecode, &expectedReturnValue, 9, &[_]u256{0x05}, &[_]u256{});
}

test "adding one to max u256 should wrap to zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(OpCode.PUSH32),  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        @intFromEnum(OpCode.PUSH1), 0x01,
        @intFromEnum(OpCode.ADD),
    };
    // zig fmt: on

    const expectedReturnValue = [_]u8{};
    const expectedGasConsumed = 9;
    const expectedStack = [_]u256{0x0};
    const expectedMemory = [_]u256{};
    try testBytecode(&bytecode, &expectedReturnValue, expectedGasConsumed, &expectedStack, &expectedMemory);
}

test "return single-byte value" {
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

    const expectedReturnValue = [_]u8{0x01};
    const expectedGasConsumed = 18;
    const expectedStack = [_]u256{};
    const expectedMemory = [_]u256{0x01};
    try testBytecode(&bytecode, &expectedReturnValue, expectedGasConsumed, &expectedStack, &expectedMemory);
}

test "return 32-byte value" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(OpCode.PUSH1), 0x01,
        @intFromEnum(OpCode.PUSH1), 0x00,
        @intFromEnum(OpCode.MSTORE),
        @intFromEnum(OpCode.PUSH1), 0x20,
        @intFromEnum(OpCode.PUSH1), 0x00,
        @intFromEnum(OpCode.RETURN),
    };
    // zig fmt: on

    const expectedReturnValue = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const expectedGasConsumed = 18;
    const expectedStack = [_]u256{};
    const expectedMemory = [_]u256{0x01};
    try testBytecode(&bytecode, &expectedReturnValue, expectedGasConsumed, &expectedStack, &expectedMemory);
}

test "use push32 and return a single byte" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(OpCode.PUSH32), 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(OpCode.PUSH1), 0x00,
        @intFromEnum(OpCode.MSTORE),
        @intFromEnum(OpCode.PUSH1), 0x01,
        @intFromEnum(OpCode.PUSH1), 0x00,
        @intFromEnum(OpCode.RETURN),
    };
    // zig fmt: on

    const expectedReturnValue = [_]u8{0x10};
    const expectedGasConsumed = 18;
    const expectedStack = [_]u256{};
    const expectedMemory = [_]u256{0x1000000000000000000000000000000000000000000000000000000000000000};
    try testBytecode(&bytecode, &expectedReturnValue, expectedGasConsumed, &expectedStack, &expectedMemory);
}

fn testReadMemory(
    memory: []const u256,
    offset: u8,
    size: u8,
    expected: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const rBytes = try readMemory(allocator, memory, offset, size);
    defer allocator.free(rBytes);
    try std.testing.expectEqualSlices(u8, expected, rBytes);
}

test "read from memory as bytes" {
    try testReadMemory(&[_]u256{
        0x0123456789abcdefaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        0x13579bdf02468ace111111111111111111111111111111111111111111111111,
    }, 0, 1, &[_]u8{0x01});
    try testReadMemory(&[_]u256{
        0x0123456789abcdefaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        0x13579bdf02468ace111111111111111111111111111111111111111111111111,
    }, 1, 1, &[_]u8{0x23});
    try testReadMemory(&[_]u256{
        0x0123456789abcdefaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        0x13579bdf02468ace111111111111111111111111111111111111111111111111,
    }, 31, 1, &[_]u8{0xaa});
    try testReadMemory(&[_]u256{
        0x0123456789abcdefaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        0x13579bdf02468ace111111111111111111111111111111111111111111111111,
    }, 31, 2, &[_]u8{ 0xaa, 0x13 });
    try testReadMemory(&[_]u256{
        0x0123456789abcdefaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        0x13579bdf02468ace111111111111111111111111111111111111111111111111,
    }, 30, 4, &[_]u8{ 0xaa, 0xaa, 0x13, 0x57 });
}