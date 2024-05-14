const std = @import("std");
const memory = @import("memory.zig");
const opcodes = @import("opcodes.zig");
const stack = @import("stack.zig");

pub const VMError = error{
    NotImplemented,
    MemoryReferenceTooLarge,
};

pub const VM = struct {
    allocator: std.mem.Allocator = undefined,
    stack: stack.Stack = stack.Stack{},
    memory: memory.ExpandableMemory = memory.ExpandableMemory{},
    return_value: []u8 = undefined,
    gas_consumed: u64 = 0,

    pub fn init(self: *VM, allocator: std.mem.Allocator) void {
        self.memory.init(allocator);
        self.allocator = allocator;
    }

    pub fn deinit(self: *VM) void {
        self.memory.deinit();
        self.allocator.free(self.return_value);
    }

    pub fn run(self: *VM, bytecode: []const u8) !void {
        var stream = std.io.fixedBufferStream(bytecode);

        while (try self.nextInstruction(&stream)) {
            std.log.debug("  Gas consumed: {}", .{self.gas_consumed});
            std.log.debug("---", .{});
        }
    }

    pub fn nextInstruction(self: *VM, stream: *std.io.FixedBufferStream([]const u8)) !bool {
        // This doesn't really matter, since the opcode is a single byte.
        const byte_order = std.builtin.Endian.big;

        const reader = stream.reader();

        const op: opcodes.OpCode = reader.readEnum(opcodes.OpCode, byte_order) catch |err| switch (err) {
            error.EndOfStream => {
                return false;
            },
            else => {
                return err;
            },
        };
        switch (op) {
            opcodes.OpCode.STOP => {
                std.log.debug("{s}", .{@tagName(op)});

                return false;
            },
            opcodes.OpCode.ADD => {
                std.log.debug("{s}", .{@tagName(op)});

                const a = try self.stack.pop();
                const b = try self.stack.pop();

                const c = a +% b;

                try self.stack.push(c);

                self.gas_consumed += 3;

                return true;
            },
            opcodes.OpCode.SUB => {
                std.log.debug("{s}", .{@tagName(op)});

                const a = try self.stack.pop();
                const b = try self.stack.pop();

                const c = a -% b;

                try self.stack.push(c);

                self.gas_consumed += 3;

                return true;
            },
            opcodes.OpCode.DIV => {
                std.log.debug("{s}", .{@tagName(op)});

                const a = try self.stack.pop();
                const b = try self.stack.pop();

                if (b == 0) {
                    try self.stack.push(0);
                } else {
                    const c = a / b;
                    try self.stack.push(c);
                }

                self.gas_consumed += 5;

                return true;
            },
            opcodes.OpCode.SDIV => {
                std.log.debug("{s}", .{@tagName(op)});

                const a: i256 = @bitCast(try self.stack.pop());
                const b: i256 = @bitCast(try self.stack.pop());

                if (b == 0) {
                    try self.stack.push(0);
                } else {
                    const c: u256 = @bitCast(@divTrunc(a, b));
                    try self.stack.push(c);
                }

                self.gas_consumed += 5;

                return true;
            },
            opcodes.OpCode.MUL => {
                std.log.debug("{s}", .{@tagName(op)});

                const a = try self.stack.pop();
                const b = try self.stack.pop();

                const c = a *% b;

                try self.stack.push(c);

                self.gas_consumed += 5;

                return true;
            },
            opcodes.OpCode.MOD => {
                std.log.debug("{s}", .{@tagName(op)});
                self.gas_consumed += 5;
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                if (b == 0) {
                    try self.stack.push(0);
                    return true;
                }
                const c = @mod(a, b);
                try self.stack.push(c);
                return true;
            },
            opcodes.OpCode.SMOD => {
                std.log.debug("{s}", .{@tagName(op)});
                self.gas_consumed += 5;

                const a: i256 = @bitCast(try self.stack.pop());
                const b: i256 = @bitCast(try self.stack.pop());
                if (b == 0) {
                    try self.stack.push(0);
                    return true;
                }

                const c: u256 = @bitCast(@mod(a, b));
                try self.stack.push(c);

                return true;
            },
            opcodes.OpCode.ISZERO => {
                std.log.debug("{s}", .{@tagName(op)});
                self.gas_consumed += 3;
                const val = try self.stack.pop();
                const is_zero: u8 = @intFromBool(val == 0);
                try self.stack.push(is_zero);
                return true;
            },
            opcodes.OpCode.NOT => {
                std.log.debug("{s}", .{@tagName(op)});
                self.gas_consumed += 3;
                const val = try self.stack.pop();
                const negated = ~val;
                try self.stack.push(negated);
                return true;
            },
            opcodes.OpCode.KECCAK256 => {
                std.log.debug("{s}", .{@tagName(op)});

                const offset = try self.stack.pop();
                const size = try self.stack.pop();

                const word_size = @sizeOf(u256) / @sizeOf(u8);
                const word_count_rounded_up = std.math.cast(u64, (size + (word_size - 1)) / word_size) orelse return VMError.MemoryReferenceTooLarge;
                self.gas_consumed += 6 * word_count_rounded_up;

                const old_length = self.memory.length();
                const input = try self.memory.read(self.allocator, offset, size);
                defer self.allocator.free(input);
                const new_length = self.memory.length();

                self.gas_consumed += memoryExpansionCost(old_length, new_length);

                std.log.debug("  Calcuating keccak256({any})", .{input});

                const Keccak256 = std.crypto.hash.sha3.Keccak256;
                var hash_bytes: [Keccak256.digest_length]u8 = undefined;
                Keccak256.hash(input, &hash_bytes, .{});

                std.debug.assert(hash_bytes.len == (256 / 8));

                const hash_value = std.mem.nativeTo(u256, std.mem.bytesToValue(u256, &hash_bytes), std.builtin.Endian.big);

                self.gas_consumed += 30;

                try self.stack.push(hash_value);

                return true;
            },
            opcodes.OpCode.CODESIZE => {
                std.log.debug("{s}", .{@tagName(op)});

                const length = try stream.getEndPos();
                try self.stack.push(length);

                self.gas_consumed += 2;

                return true;
            },
            opcodes.OpCode.POP => {
                std.log.debug("{s}", .{
                    @tagName(op),
                });
                _ = try self.stack.pop();
                self.gas_consumed += 2;
                return true;
            },
            opcodes.OpCode.PUSH0 => {
                std.log.debug("{s}", .{@tagName(op)});

                self.gas_consumed += 2;

                _ = try self.stack.push(0);

                return true;
            },
            opcodes.OpCode.PUSH1 => {
                const b = try reader.readByte();
                std.log.debug("{s} 0x{x:0>2}", .{ @tagName(op), b });
                try self.stack.push(b);
                self.gas_consumed += 3;
                return true;
            },
            opcodes.OpCode.PUSH32 => {
                const b = try reader.readInt(u256, std.builtin.Endian.big);
                std.log.debug("{s} 0x{x:0>32}", .{ @tagName(op), b });
                try self.stack.push(b);
                self.gas_consumed += 3;
                return true;
            },
            opcodes.OpCode.MSTORE => {
                std.log.debug("{s}", .{@tagName(op)});
                const offset = try self.stack.pop();
                const value = try self.stack.pop();

                const old_length = self.memory.length();
                try self.memory.write(offset, value);
                const new_length = self.memory.length();
                self.gas_consumed += memoryExpansionCost(old_length, new_length);

                self.gas_consumed += 3;
                return true;
            },
            opcodes.OpCode.PC => {
                std.log.debug("{s}", .{@tagName(op)});

                const pos = try stream.getPos();
                try self.stack.push(pos - 1);
                self.gas_consumed += 2;

                return true;
            },
            opcodes.OpCode.RETURN => {
                std.log.debug("{s}", .{@tagName(op)});
                const offset = try self.stack.pop();
                const size = try self.stack.pop();

                self.return_value = try self.memory.read(self.allocator, offset, size);
                std.log.debug("  Return value: 0x{}", .{std.fmt.fmtSliceHexLower(self.return_value)});
                return true;
            },
            else => {
                std.log.err("Not yet handling opcode {d}", .{op});
                return VMError.NotImplemented;
            },
        }
    }
};

fn memoryLengthToStateSize(length: usize) u64 {
    return @as(u64, ((length << 2) / 512) + (3 * length));
}

fn memoryExpansionCost(old_length: usize, new_length: usize) u64 {
    return @as(u64, memoryLengthToStateSize(new_length) - memoryLengthToStateSize(old_length));
}

fn expectGasConsumed(expected: u64, actual: u64) !void {
    if (expected == actual) {
        return;
    }
    std.debug.print("incorrect gas consumed\n", .{});
    std.debug.print("expected {d} gas, found {d} gas\n", .{ expected, actual });
    return error.TestExpectedEqual;
}

fn testBytecode(bytecode: []const u8, expected_return_value: []const u8, expected_gas_consumed: u64, expected_stack: []const u256, expected_memory: []const u256) !void {
    const allocator = std.testing.allocator;

    var vm = VM{};
    vm.init(allocator);
    defer vm.deinit();

    try vm.run(bytecode);

    try std.testing.expectEqualSlices(u8, expected_return_value, vm.return_value);
    try expectGasConsumed(expected_gas_consumed, vm.gas_consumed);
    try std.testing.expectEqualSlices(u256, expected_stack, vm.stack.slice());
    try std.testing.expectEqualSlices(u256, expected_memory, vm.memory.slice());
}

test "exit immediately" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.STOP)
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 0;
    const expected_stack = [_]u256{};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "push zero to stack with PUSH0" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH0),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 2;
    const expected_stack = [_]u256{0x00};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "exit after pushing two values to stack" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.STOP),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 6;
    const expected_stack = [_]u256{ 0x02, 0x01 };
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "add two bytes" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.ADD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 9;
    const expected_stack = [_]u256{0x05};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "adding one to max u256 should wrap to zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.ADD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 9;
    const expected_stack = [_]u256{0x0};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "multiply two bytes with no integer overflow" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.MUL),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x06};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "multiply two bytes and allow integer overflow" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.MUL),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "subtract two bytes" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x08,
        @intFromEnum(opcodes.OpCode.SUB),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 9;
    const expected_stack = [_]u256{0x06};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "subtracting 1 from 0 should underflow to 2^256 - 1" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.SUB),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 9;
    const expected_stack = [_]u256{0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "divide two bytes where there is no remainder" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x06,
        @intFromEnum(opcodes.OpCode.DIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x02};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "divide two bytes and round down the remainder" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x05,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x09,
        @intFromEnum(opcodes.OpCode.DIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x01};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "dividing any whole number by zero is zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x06,
        @intFromEnum(opcodes.OpCode.DIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x0};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "dividing zero by zero is zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.DIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x0};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed divide two bytes where there is no remainder" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x06,
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x02};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed divide a 32-bit number" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x02};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed divide a negative number by a positive number is a negative number" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 5,
        // Push -25 onto stack
        @intFromEnum(opcodes.OpCode.PUSH1), 25,
        @intFromEnum(opcodes.OpCode.PUSH1), 0,
        @intFromEnum(opcodes.OpCode.SUB),
        // -25 / 5
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 3 + 3 + 5;
    const expected_stack = [_]u256{@bitCast(@as(i256, -5))};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed divide a negative number by a negative number is a positive number" {
    // zig fmt: off
    const bytecode = [_]u8{
        // Push -5 onto stack
        @intFromEnum(opcodes.OpCode.PUSH1), 5,
        @intFromEnum(opcodes.OpCode.PUSH1), 0,
        @intFromEnum(opcodes.OpCode.SUB),
        // Push -25 onto stack
        @intFromEnum(opcodes.OpCode.PUSH1), 25,
        @intFromEnum(opcodes.OpCode.PUSH1), 0,
        @intFromEnum(opcodes.OpCode.SUB),
        // -25 / -5
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = (3 + 3 + 3) + (3 + 3 + 3) + 5;
    const expected_stack = [_]u256{0x05};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed dividing any whole number by zero is zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x06,
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x0};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "signed dividing zero by zero is zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.SDIV),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x0};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "10 modulus 3 is 1" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x0a,
        @intFromEnum(opcodes.OpCode.MOD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 11;
    const expected_stack = [_]u256{0x01};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "anything mod 0 is 0" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x05,
        @intFromEnum(opcodes.OpCode.MOD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 11;
    const expected_stack = [_]u256{0x00};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "17 signed modulus 5 is 2" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x05,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x11,
        @intFromEnum(opcodes.OpCode.SMOD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x02};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "-8 signed modulus -3 is -2" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfd,
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8,
        @intFromEnum(opcodes.OpCode.SMOD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "anything signed mod 0 is 0" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x11,
        @intFromEnum(opcodes.OpCode.SMOD),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3 + 5;
    const expected_stack = [_]u256{0x00};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "verify zero is zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.ISZERO),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 6;
    const expected_stack = [_]u256{0x01};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "verify seven is not zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x07,
        @intFromEnum(opcodes.OpCode.ISZERO),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 6;
    const expected_stack = [_]u256{0x00};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "bitwise not flips all bits of zero" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.NOT),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3;
    const expected_stack = [_]u256{0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "bitwise not flips all 1 bits to 0" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        @intFromEnum(opcodes.OpCode.NOT),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3;
    const expected_stack = [_]u256{0x00};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "bitwise not flips all 1 bits to 0 in mixed values" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0,
        @intFromEnum(opcodes.OpCode.NOT),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 3;
    const expected_stack = [_]u256{0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0f};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "push elements to the stack and then pop them off" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x02,
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x03,
        @intFromEnum(opcodes.OpCode.POP),
        @intFromEnum(opcodes.OpCode.POP),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x04,
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = (3 * 5) + (2 * 2);
    const expected_stack = [_]u256{ 0x01, 0x02, 0x04 };
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "calculate a keccak hash of a 32-bit value" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x04,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.KECCAK256),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 54;
    const expected_stack = [_]u256{0x29045a592007d0c246ef02c2223570da9522d0cf0f73282c79a1bc8f0bb2c238};
    const expected_memory = [_]u256{0xffffffff00000000000000000000000000000000000000000000000000000000};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "calculate a keccak hash of a 32-bit value twice" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x04,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.KECCAK256),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x04,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.KECCAK256),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 102;
    const expected_stack = [_]u256{0xc05f009506ab1986a4bf586e65fdc9fbfc7004b07f136ab5378d89e8db9f43b5};
    const expected_memory = [_]u256{0x29045a592007d0c246ef02c2223570da9522d0cf0f73282c79a1bc8f0bb2c238};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "check codesize of a single instruction" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.CODESIZE)
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 2;
    const expected_stack = [_]u256{0x01};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "check codesize of multiple instructions" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.POP),
        @intFromEnum(opcodes.OpCode.CODESIZE)
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 3 + 2 + 2;
    const expected_stack = [_]u256{1 + 32 + 1 + 1};
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "return single-byte value" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x1f,
        @intFromEnum(opcodes.OpCode.RETURN),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{0x01};
    const expected_gas_consumed = 18;
    const expected_stack = [_]u256{};
    const expected_memory = [_]u256{0x01};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "return 32-byte value" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x20,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.RETURN),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const expected_gas_consumed = 18;
    const expected_stack = [_]u256{};
    const expected_memory = [_]u256{0x01};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "use push32 and return a single byte" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH1), 0x01,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.RETURN),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{0x10};
    const expected_gas_consumed = 18;
    const expected_stack = [_]u256{};
    const expected_memory = [_]u256{0x1000000000000000000000000000000000000000000000000000000000000000};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "MSTORE and then overwrite" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PUSH32), 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
        @intFromEnum(opcodes.OpCode.PUSH32), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff,
        @intFromEnum(opcodes.OpCode.PUSH1), 0x00,
        @intFromEnum(opcodes.OpCode.MSTORE),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = 21;
    const expected_stack = [_]u256{};
    const expected_memory = [_]u256{0x000000000000000000000000000000000000000000000000000000000000ffff};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}

test "use pc to measure program counter" {
    // zig fmt: off
    const bytecode = [_]u8{
        @intFromEnum(opcodes.OpCode.PC),
        @intFromEnum(opcodes.OpCode.PC),
        @intFromEnum(opcodes.OpCode.PUSH1), 0xaa,
        @intFromEnum(opcodes.OpCode.PC),
        @intFromEnum(opcodes.OpCode.PUSH32), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xbb,
        @intFromEnum(opcodes.OpCode.PC),
    };
    // zig fmt: on

    const expected_return_value = [_]u8{};
    const expected_gas_consumed = (4 * 2) + (3 * 2);
    const expected_stack = [_]u256{ 0x00, 0x01, 0xaa, 0x04, 0x00000000000000000000000000000000000000000000000000000000000000bb, 4 + 1 + 1 + 32 };
    const expected_memory = [_]u256{};
    try testBytecode(&bytecode, &expected_return_value, expected_gas_consumed, &expected_stack, &expected_memory);
}
