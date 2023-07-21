const std = @import("std");

const Xoshiro128 = std.rand.Xoroshiro128;

const path_dens = 6;
const map_rows: usize = 15;
const map_cols: usize = 7;

const location_distribution = [_]f32{
    0.45, // Monster
    0.22, // Event
    0.16, // Elite
    0.12, // Rest
    0.05, // Merchant
    0.00, // Treasure
};

const LocationKind = enum {
    Monster,
    Event,
    Elite,
    Rest,
    Merchant,
    Treasure,
};

const Location = struct {
    edge_indices: [3]?usize = [_]?usize{ null, null, null },
    kind: LocationKind = undefined,

    inline fn insertEdge(loc: *Location, target_index: usize) void {
        for (&loc.edge_indices) |*edge_index| {
            if (edge_index.* == null) {
                edge_index.* = target_index;
            }
        }
    }

    inline fn hasAnyEdges(loc: *const Location) bool {
        for (loc.edge_indices) |edge_index|
            if (edge_index != null) return true;
        return false;
    }

    inline fn hasEdgeWithIndex(loc: *const Location, target_index: usize) bool {
        for (loc.edge_indices) |edge_index|
            if (edge_index != null and edge_index == target_index) return true;
        return false;
    }
};

/// Flips floor_index. 'map_rows - floor_index - 1'
inline fn floorIndexToMapRowIndex(floor_index: usize) usize {
    std.debug.assert(floor_index < map_rows);
    return map_rows - floor_index - 1;
}

fn determineLocationKind(rand: std.rand.Random, map: []Location, coords: @Vector(2, usize)) LocationKind {
    // These floors ALLWAYS contain these location kinds.
    if (coords[1] == 0) return LocationKind.Monster;
    if (coords[1] == 8) return LocationKind.Treasure;
    if (coords[1] == 14) return LocationKind.Rest;

    _ = map;

    while (true) {
        const location_kind = @as(LocationKind, @enumFromInt(rand.weightedIndex(f32, &location_distribution)));

        // 1.) Elites and Rest sites can't be assigned bellow 6th floor.
        if (location_kind == .Elite and coords[1] < 5) continue;

        // 2.) Elite, Merchant and Rest Site cannot be consecutive. (eg. you can't have 2 Rest Sites connected with a Path)
        // if (1 << @intFromEnum(location_kind) & (
        //    (1 << @intFromEnum(LocationKind.Elite)) |
        //    (1 << @intFromEnum(LocationKind.Merchant)) |
        //    (1 << @intFromEnum(LocationKind.Rest))) != 0) {
        //     for (0..coords[0] + 1) |col_index| {
        //         if (map[(floorIndexToMapRowIndex(coords[1]) - 1) * map_cols + col_index].edge_index != null)
        //             map[(floorIndexToMapRowIndex(coords[1]) - 1) * map_cols + col_index].kind =
        //     }
        // }

        // 3.) A Room that that has 2 or more Paths going out must have all destinations
        // be unique. 2 destinations originating form the same Room cannot share the same Location.
        // TODO(caleb)

        // 4.) Rest Site cannot be on the 14th Floor.
        if (location_kind == .Rest and coords[1] == 13) continue;

        return location_kind;
    }
}

pub fn main() !void {
    var map: [map_rows * map_cols]Location = undefined;
    for (0..map_rows * map_cols) |map_index| map[map_index] = Location{};

    var xoshi = Xoshiro128.init(7);
    var rand = xoshi.random();

    // Map layout
    for (0..path_dens) |path_gen_index| {
        var curr_col_index = rand.uintLessThan(u8, map_cols);
        if (path_gen_index == 1) { // Edge case, make sure first floor has at least 2 rooms.
            while (true) : (curr_col_index = rand.uintLessThan(u8, map_cols))
                if (!map[(map_rows - 1) + map_cols + curr_col_index].hasAnyEdges()) break;
        }
        for (0..map_rows) |row_index| {
            map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].insertEdge(std.math.maxInt(usize)); // Assume next floor is boss

            // Next floor isn't boss
            if (row_index < map_rows - 1) { // Create path to room on next floor and move to that floor.
                var at_least_col_dx = if (curr_col_index > 0) @as(i8, -1) else @as(i8, 0);
                var less_than_col_dx = if (curr_col_index < map_cols - 1) @as(i8, 2) else @as(i8, 1);
                if ((curr_col_index > 0) and
                    (map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index - 1].hasEdgeWithIndex((floorIndexToMapRowIndex(row_index) - 1) * map_cols + curr_col_index)))
                    at_least_col_dx += 1;
                if ((curr_col_index < map_cols - 1) and
                    (map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index + 1].hasEdgeWithIndex((floorIndexToMapRowIndex(row_index) - 1) * map_cols + curr_col_index)))
                    less_than_col_dx -= 1;
                const next_col_dx = rand.intRangeLessThan(i8, at_least_col_dx, less_than_col_dx);
                map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].insertEdge((floorIndexToMapRowIndex(row_index) - 1) * map_cols + @as(usize, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx)));
                curr_col_index = @as(u8, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx));
            }
        }
    }

    // Assign locations
    for (0..map_rows) |row_index| {
        for (0..map_cols) |col_index| {
            if (map[floorIndexToMapRowIndex(row_index) * map_cols + col_index].hasAnyEdges())
                map[floorIndexToMapRowIndex(row_index) * map_cols + col_index].kind =
                    determineLocationKind(rand, &map, @Vector(2, usize){ col_index, row_index });
        }
    }

    std.debug.print("\tboss floor\n", .{});
    for (0..map_rows) |row_index| {
        std.debug.print("{d:2}. ", .{@as(u8, @intCast(map_rows - row_index - 1))});
        for (0..map_cols) |col_index| {
            if (map[row_index * map_cols + col_index].hasAnyEdges()) {
                std.debug.print("{s}  ", .{@tagName(map[row_index * map_cols + col_index].kind)[0..2]});
            } else {
                std.debug.print("    ", .{});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("    ", .{});
    for (0..map_cols) |col_index| std.debug.print("{d:1}.  ", .{col_index});
    std.debug.print("\n", .{});
}
