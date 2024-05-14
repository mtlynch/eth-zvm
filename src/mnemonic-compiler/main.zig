const std = @import("std");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print("Usage: {s} <mnemonic-file> <output-file>\n", .{args[0]});
        return;
    }

    const infile_path = args[1];
    const infile = try std.fs.cwd().openFile(infile_path, .{});
    defer infile.close();

    const tokens = try tokenizer.tokenize(infile.reader(), allocator);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    const bytecode = try parser.parseTokens(tokens, allocator);
    defer allocator.free(bytecode);

    const outfile_path = args[2];
    const outfile = try std.fs.cwd().createFile(outfile_path, .{});
    defer outfile.close();

    const buf: []u8 = try allocator.alloc(u8, bytecode.len * 2);
    defer allocator.free(buf);
    _ = try std.fmt.bufPrint(buf, "{x}", .{std.fmt.fmtSliceHexLower(bytecode)});

    try outfile.writeAll(buf);
}

test {
    std.testing.refAllDecls(@This());
}
