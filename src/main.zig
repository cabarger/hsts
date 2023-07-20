const std = @import("std");

const Xoshiro128 = std.rand.Xoroshiro128;

const Node = struct {
    edge_index: ?usize = null,
};

pub fn main() !void {
    const path_dens = 2;
    const map_rows: usize = 15;
    const map_cols: usize = 7;
    var map: [map_rows * map_cols]Node = undefined;
    for (0..map_rows * map_cols) |map_index| map[map_index] = Node{};

    var xoshi = Xoshiro128.init(7);
    var rand = xoshi.random();

    // TODO(caleb): Check path's don't overlap

    for (0..path_dens) |path_gen_index| {
        var curr_col_index = rand.uintLessThan(u8, map_cols);
        if (path_gen_index == 1) { // Edge case, make sure first floor has at least 2 rooms.
            while (true) : (curr_col_index = rand.uintLessThan(u8, map_cols))
                if (map[(map_rows - 1) + map_cols + curr_col_index].edge_index == null) break;
        }

        for (0..map_rows) |row_index| {
            const map_floor_y_index = map_rows - row_index - 1;
            map[map_floor_y_index * map_cols + curr_col_index].edge_index = std.math.maxInt(usize); // Assume next floor is boss

            // Next floor isn't boss
            if (row_index < map_rows - 1) { // Create path to room on next floor and move to that floor.
                var at_least_col_dx = if (curr_col_index > 0) @as(i8, -1) else @as(i8, 0);
                var less_than_col_dx = if (curr_col_index < map_cols - 1) @as(i8, 2) else @as(i8, 1);
                if ((curr_col_index > 0) and
                    (map[map_floor_y_index * map_cols + curr_col_index - 1].edge_index != null) and
                    (map[map_floor_y_index * map_cols + curr_col_index - 1].edge_index == (map_floor_y_index - 1) * map_cols + curr_col_index))
                    at_least_col_dx += 1;
                if ((curr_col_index < map_cols - 1) and
                    (map[map_floor_y_index * map_cols + curr_col_index + 1].edge_index != null) and
                    (map[map_floor_y_index * map_cols + curr_col_index + 1].edge_index == (map_floor_y_index - 1) * map_cols + curr_col_index))
                    less_than_col_dx -= 1;
                const next_col_dx = rand.intRangeLessThan(i8, at_least_col_dx, less_than_col_dx);
                map[map_floor_y_index * map_cols + curr_col_index].edge_index = (map_floor_y_index - 1) * map_cols + @as(usize, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx));
                curr_col_index = @as(u8, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx));
            }
        }
    }
    std.debug.print("\tboss floor\n", .{});
    for (0..map_rows) |row_index| {
        std.debug.print("{d:2}. ", .{@as(u8, @intCast(map_rows - row_index - 1))});
        for (0..map_cols) |col_index| {
            if (map[row_index * map_cols + col_index].edge_index != null) {
                std.debug.print("X  ", .{});
            } else {
                std.debug.print("   ", .{});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("    ", .{});
    for (0..map_cols) |col_index| std.debug.print("{d:1}. ", .{col_index});
    std.debug.print("\n", .{});
}
