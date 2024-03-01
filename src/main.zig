const std = @import("std");
const time = std.time;
const Timer = std.time.Timer;
const stack = @import("stack.zig");
const vm = @import("vm.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var reader = std.io.getStdIn().reader();

    var evm = vm.VM{};
    evm.init(allocator);
    defer evm.deinit();

    var timer = try Timer.start();
    const start = timer.lap();
    try evm.run(&reader);
    const end = timer.read();
    const elapsed_micros = @as(f64, @floatFromInt(end - start)) / time.ns_per_us;

    const output = std.io.getStdOut().writer();
    try output.print("EVM gas used:    {}\n", .{evm.gasConsumed});
    try output.print("execution time:  {d:.3}µs\n", .{elapsed_micros});
    if (evm.returnValue.len > 0) {
        try output.print("0x{}\n", .{std.fmt.fmtSliceHexLower(evm.returnValue)});
    } else {
        // Match evm behavior by outputting a blank line when there is no return value.
        try output.print("\n", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}
