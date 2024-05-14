const std = @import("std");
const evm = @import("evm");
const builtin = @import("builtin");

pub const ParserError = error{
    UnexpectedToken,
};

pub fn parseTokens(tokens: []const [:0]const u8, allocator: std.mem.Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // We don't parse very rigorously. We assume well-formed input. We generate
    // bytecode even when the token sequences are invalid (e.g., PUSH1 0x1 0x2).
    var current_opcode: evm.OpCode = undefined;
    for (tokens) |token| {
        if (parseOpcode(token)) |opcode| {
            current_opcode = opcode;
            try bytecode.append(@intFromEnum(opcode));
        } else {
            switch (current_opcode) {
                evm.OpCode.PUSH1 => {
                    const value = v: {
                        if (std.mem.startsWith(u8, token, "-")) {
                            break :v @as(u8, @bitCast(try parseValue(i8, token)));
                        } else {
                            break :v try parseValue(u8, token);
                        }
                    };
                    try bytecode.append(value);
                },
                evm.OpCode.PUSH32 => {
                    const value = try parseValue(u256, token);
                    var bytes = std.mem.toBytes(value);
                    if (isSystemLittleEndian()) {
                        // Switch from little-endian to big-endian.
                        std.mem.reverse(u8, &bytes);
                    }

                    try bytecode.appendSlice(&bytes);
                },
                else => {
                    return ParserError.UnexpectedToken;
                },
            }
        }
    }

    return bytecode.toOwnedSlice();
}

fn parseOpcode(val: [:0]const u8) ?evm.OpCode {
    // Reverse OpCode enums into a map of int values to enums.
    const keywords = std.ComptimeStringMap(evm.OpCode, comptime build_kvs: {
        const KV = struct { []const u8, evm.OpCode };
        var kvs_array: [std.meta.fields(evm.OpCode).len]KV = undefined;
        for (std.meta.fields(evm.OpCode), 0..) |enumField, i| {
            kvs_array[i] = .{ enumField.name, @enumFromInt(enumField.value) };
        }
        break :build_kvs kvs_array;
    });

    return keywords.get(val);
}

fn parseValue(comptime T: type, val: [:0]const u8) !T {
    return std.fmt.parseInt(T, val, 0);
}

fn isSystemLittleEndian() bool {
    return builtin.target.cpu.arch.endian() == std.builtin.Endian.little;
}

fn testParseTokens(tokens: []const [:0]const u8, bytecodeExpected: []const u8) !void {
    const allocator = std.testing.allocator;

    const bytecode = try parseTokens(tokens, allocator);
    defer allocator.free(bytecode);

    try std.testing.expectEqualSlices(u8, bytecodeExpected, bytecode);
}

test "parse single token" {
    const tokens = [_][:0]const u8{"RETURN"};
    const expected = [_]u8{@intFromEnum(evm.OpCode.RETURN)};

    try testParseTokens(&tokens, &expected);
}

test "parse PUSH1 call as hex" {
    const tokens = [_][:0]const u8{ "PUSH1", "0x01" };
    const expected = [_]u8{ @intFromEnum(evm.OpCode.PUSH1), 0x01 };

    try testParseTokens(&tokens, &expected);
}

test "parse PUSH1 call as decimal" {
    const tokens = [_][:0]const u8{ "PUSH1", "1" };
    const expected = [_]u8{ @intFromEnum(evm.OpCode.PUSH1), 0x01 };

    try testParseTokens(&tokens, &expected);
}

test "parse PUSH1 call as negative decimal" {
    const tokens = [_][:0]const u8{ "PUSH1", "-1" };
    const expected = [_]u8{ @intFromEnum(evm.OpCode.PUSH1), 0xFF };

    try testParseTokens(&tokens, &expected);
}

test "parse PUSH32 call" {
    const tokens = [_][:0]const u8{ "PUSH32", "0x01" };
    // zig fmt: off
    const expected = [_]u8{ @intFromEnum(evm.OpCode.PUSH32), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, };
    // zig fmt: on

    try testParseTokens(&tokens, &expected);
}

test "parse simple program" {
    // zig fmt: off
    const tokens = [_][:0]const u8{
      "PUSH1", "0x01",
      "PUSH1", "0x0",
      "MSTORE",
      "PUSH1", "0x01",
      "PUSH1", "0x1f",
      "RETURN"
      };
    const expected = [_]u8{
        @intFromEnum(evm.OpCode.PUSH1), 0x01,
        @intFromEnum(evm.OpCode.PUSH1), 0x00,
        @intFromEnum(evm.OpCode.MSTORE),
        @intFromEnum(evm.OpCode.PUSH1), 0x01,
        @intFromEnum(evm.OpCode.PUSH1), 0x1f,
        @intFromEnum(evm.OpCode.RETURN),
    };
    // zig fmt: on

    try testParseTokens(&tokens, &expected);
}
