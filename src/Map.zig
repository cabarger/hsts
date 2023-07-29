const std = @import("std");
const Location = @import("Location.zig");

const Self = @This();

pub const path_dens = 6;
pub const rows = 15;
pub const cols = 7;

pub const boss_floor_edge_index = std.math.maxInt(usize);
pub const neow_floor_edge_index = std.math.maxInt(usize) - 1;

const location_distribution = [_]f32{
    0.45, // monster
    0.22, // event
    0.16, // elite
    0.12, // rest
    0.05, // merchant
    0.00, // treasure
};

location_nodes: [rows * cols]Location = undefined,

fn parentLocations(self: *Self, coords: @Vector(2, usize)) [3]?*Location {
    var result = [3]?*Location{ null, null, null };
    for ([_]@Vector(2, i8){ @Vector(2, i8){ -1, -1 }, @Vector(2, i8){ 0, -1 }, @Vector(2, i8){ 1, -1 } }, 0..) |d_room_coords, room_index| {
        if ((@as(i8, @intCast(coords[0])) + d_room_coords[0]) >= 0 and
            (@as(i8, @intCast(coords[0])) + d_room_coords[0] < cols))
        {
            const parent_index = floorIndexToMapRowIndex(@as(usize, @intCast(@as(i8, @intCast(coords[1])) + d_room_coords[1]))) *
                cols + @as(usize, @intCast(@as(i8, @intCast(coords[0])) + d_room_coords[0]));
            if (self.location_nodes[parent_index].hasEdgeWithIndex(floorIndexToMapRowIndex(coords[1]) * cols + coords[0]))
                result[room_index] = &self.location_nodes[parent_index];
        }
    }
    return result;
}

pub inline fn floorIndexToMapRowIndex(floor_index: usize) usize {
    std.debug.assert(floor_index < rows);
    return rows - floor_index - 1;
}

pub inline fn locationFromFloorAndColIndex(self: *Self, floor_index: u8, col_index: u8) Location {
    return self.location_nodes[floorIndexToMapRowIndex(floor_index) * cols + col_index];
}

pub fn determineLocationType(self: *Self, rand: std.rand.Random, coords: @Vector(2, usize)) Location.Type {
    // These floors ALLWAYS contain these location types.
    if (coords[1] == 0) return Location.Type.monster;
    if (coords[1] == 8) return Location.Type.treasure;
    if (coords[1] == 14) return Location.Type.rest;

    outer: while (true) {
        const location_type = @as(Location.Type, @enumFromInt(rand.weightedIndex(f32, &location_distribution)));

        // 1.) Rest Site cannot be on the 14th Floor.
        if (location_type == .rest and coords[1] == 13) continue;

        // 2.) Elites and rest sites can't be assigned bellow 6th floor.
        if ((location_type == .elite or location_type == .rest) and coords[1] < 5) continue;

        // 3.) Elite, Merchant and rest Site cannot be consecutive. (eg. you can't have 2 rest sites connected with a path)
        if ((location_type == .elite) or (location_type == .merchant) or (location_type == .rest)) {
            for (self.parentLocations(coords)) |opt_parent_location| {
                if (opt_parent_location != null and opt_parent_location.?.type == location_type) continue :outer;
            }
        }

        // 4.) A Room that that has 2 or more Paths going out must have all destinations
        // be unique. 2 destinations originating form the same Room cannot share the same Location.
        for (self.parentLocations(coords)) |opt_parent_location| {
            if (opt_parent_location != null and opt_parent_location.?.edgeCount() > 1) {
                for (opt_parent_location.?.edge_indices) |opt_edge_index| {
                    if ((opt_edge_index != null) and
                        (floorIndexToMapRowIndex(coords[1]) * cols + coords[0] != opt_edge_index.?) and
                        (self.location_nodes[opt_edge_index.?].type == location_type)) continue :outer;
                }
            }
        }

        return location_type;
    }
}

pub fn generate(self: *Self, rand: std.rand.Random) void {
    for (0..rows * cols) |map_index| self.location_nodes[map_index] = Location{};

    // Map layout
    for (0..path_dens) |path_gen_index| {
        var curr_col_index = rand.uintLessThan(u8, cols);
        if (path_gen_index == 1) { // Edge case, make sure first floor has at least 2 rooms.
            while (true) : (curr_col_index = rand.uintLessThan(u8, cols))
                if (self.location_nodes[(rows - 1) + cols + curr_col_index].edgeCount() == 0) break;
        }
        for (0..rows) |row_index| {
            // If the next floor isn't boss, create path to room on next floor and move to that room.
            if (row_index < rows - 1) {
                var at_least_col_dx = if (curr_col_index > 0) @as(i8, -1) else @as(i8, 0);
                var less_than_col_dx = if (curr_col_index < cols - 1) @as(i8, 2) else @as(i8, 1);
                if ((curr_col_index > 0) and
                    (self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + curr_col_index - 1]
                    .hasEdgeWithIndex(floorIndexToMapRowIndex(row_index + 1) * cols + curr_col_index)))
                    at_least_col_dx += 1;
                if ((curr_col_index < cols - 1) and
                    (self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + curr_col_index + 1]
                    .hasEdgeWithIndex(floorIndexToMapRowIndex(row_index + 1) * cols + curr_col_index)))
                    less_than_col_dx -= 1;
                const next_col_dx = rand.intRangeLessThan(i8, at_least_col_dx, less_than_col_dx);
                self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + curr_col_index].insertEdge(floorIndexToMapRowIndex(row_index + 1) *
                    cols + @as(usize, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx)));
                self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + curr_col_index].path_generation_index = @as(u8, @truncate(path_gen_index));
                curr_col_index = @as(u8, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx));
            } else {
                self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + curr_col_index].insertEdge(boss_floor_edge_index);
            }
        }
    }

    // Assign locations
    for (0..rows) |row_index| {
        for (0..cols) |col_index| {
            if (self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + col_index].edgeCount() > 0)
                self.location_nodes[floorIndexToMapRowIndex(row_index) * cols + col_index].type =
                    self.determineLocationType(rand, @Vector(2, usize){ col_index, row_index });
        }
    }
}
