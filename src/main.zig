const std = @import("std");

const Node = struct {
    xpos: u8 = 0,
    ypos: u8 = 0,
};

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!

    // 15 - 1
    // ...
    // 15 - 14 + 1 => 15 = 0 V

    const map_rows: usize = 15;
    const map_cols: usize = 7;
    var map: [map_rows * map_cols]Node = undefined;
    for (0..map_rows) |row_index| {
        for (0..map_cols) |col_index| {
            map[row_index * map_cols + col_index] = Node{ .xpos = @intCast(u8, col_index), .ypos = @intCast(u8, map_rows - row_index - 1) };
            std.debug.print("({d}, {d}) ", .{ map[row_index * map_cols + col_index].xpos, map[row_index * map_cols + col_index].ypos });
        }
        std.debug.print("\n", .{});
    }
}
