const std = @import("std");

const fmt = std.fmt;

const Xoshiro128 = std.rand.Xoroshiro128;

const path_dens = 6;
const map_rows: usize = 15;
const map_cols: usize = 7;
const seed = 5;
const cards_csv_path = "cards.csv";

const location_distribution = [_]f32{
    0.45, // monster
    0.22, // event
    0.16, // elite
    0.12, // rest
    0.05, // merchant
    0.00, // treasure
};

const LocationType = enum {
    monster,
    event,
    elite,
    rest,
    merchant,
    treasure,
};

const CardType = enum {
    attack,
    skill,
    power,
    status,
    curse,
};

// const Relic = enum {};
// const relic_names = [_][]const u8{
//     "Burning Blood",
// };

const WTFDoDim = enum {
    damage,
    block,
    vulnerable,

    len,
};

const Location = struct {
    edge_indices: [3]?usize = [_]?usize{ null, null, null },
    type: LocationType = undefined,
    path_generation_index: u8 = undefined,

    inline fn insertEdge(loc: *Location, target_index: usize) void {
        for (&loc.edge_indices) |*edge_index| {
            if (edge_index.* == null) {
                edge_index.* = target_index;
            }
        }
    }

    inline fn edgeCount(loc: *const Location) usize {
        var result: usize = 0;
        for (loc.edge_indices) |edge_index| {
            if (edge_index != null) result += 1;
        }
        return result;
    }

    inline fn hasEdgeWithIndex(loc: *const Location, target_index: usize) bool {
        for (loc.edge_indices) |edge_index|
            if (edge_index != null and edge_index == target_index) return true;
        return false;
    }
};

fn parentLocations(map: []Location, coords: @Vector(2, usize)) [3]?*Location {
    var result = [3]?*Location{ null, null, null };
    for ([_]@Vector(2, i8){ @Vector(2, i8){ -1, -1 }, @Vector(2, i8){ 0, -1 }, @Vector(2, i8){ 1, -1 } }, 0..) |d_room_coords, room_index| {
        if ((@as(i8, @intCast(coords[0])) + d_room_coords[0]) >= 0 and
            (@as(i8, @intCast(coords[0])) + d_room_coords[0] < map_cols))
        {
            const parent_index = floorIndexToMapRowIndex(@as(usize, @intCast(@as(i8, @intCast(coords[1])) + d_room_coords[1]))) *
                map_cols + @as(usize, @intCast(@as(i8, @intCast(coords[0])) + d_room_coords[0]));
            if (map[parent_index].hasEdgeWithIndex(floorIndexToMapRowIndex(coords[1]) * map_cols + coords[0]))
                result[room_index] = &map[parent_index];
        }
    }
    return result;
}

/// Flips floor_index. 'map_rows - floor_index - 1'
inline fn floorIndexToMapRowIndex(floor_index: usize) usize {
    std.debug.assert(floor_index < map_rows);
    return map_rows - floor_index - 1;
}

fn determineLocationType(rand: std.rand.Random, map: []Location, coords: @Vector(2, usize)) LocationType {
    // These floors ALLWAYS contain these location types.
    if (coords[1] == 0) return LocationType.monster;
    if (coords[1] == 8) return LocationType.treasure;
    if (coords[1] == 14) return LocationType.rest;

    outer: while (true) {
        const location_type = @as(LocationType, @enumFromInt(rand.weightedIndex(f32, &location_distribution)));

        // 1.) Rest Site cannot be on the 14th Floor.
        if (location_type == .rest and coords[1] == 13) continue;

        // 2.) Elites and rest sites can't be assigned bellow 6th floor.
        if ((location_type == .elite or location_type == .rest) and coords[1] < 5) continue;

        // 3.) Elite, Merchant and rest Site cannot be consecutive. (eg. you can't have 2 rest sites connected with a path)
        if ((location_type == .elite) or (location_type == .merchant) or (location_type == .rest)) {
            for (parentLocations(map, coords)) |opt_parent_location| {
                if (opt_parent_location != null and opt_parent_location.?.type == location_type) continue :outer;
            }
        }

        // 4.) A Room that that has 2 or more Paths going out must have all destinations
        // be unique. 2 destinations originating form the same Room cannot share the same Location.
        for (parentLocations(map, coords)) |opt_parent_location| {
            if (opt_parent_location != null and opt_parent_location.?.edgeCount() > 1) {
                for (opt_parent_location.?.edge_indices) |opt_edge_index| {
                    if ((opt_edge_index != null) and
                        (floorIndexToMapRowIndex(coords[1]) * map_cols + coords[0] != opt_edge_index.?) and
                        (map[opt_edge_index.?].type == location_type)) continue :outer;
                }
            }
        }

        return location_type;
    }
}

pub fn generateMap(rand: std.rand.Random, map: []Location) void {
    for (0..map_rows * map_cols) |map_index| map[map_index] = Location{};

    // Map layout
    for (0..path_dens) |path_gen_index| {
        var curr_col_index = rand.uintLessThan(u8, map_cols);
        if (path_gen_index == 1) { // Edge case, make sure first floor has at least 2 rooms.
            while (true) : (curr_col_index = rand.uintLessThan(u8, map_cols))
                if (map[(map_rows - 1) + map_cols + curr_col_index].edgeCount() == 0) break;
        }
        for (0..map_rows) |row_index| {
            // If the next floor isn't boss, create path to room on next floor and move to that room.
            if (row_index < map_rows - 1) {
                var at_least_col_dx = if (curr_col_index > 0) @as(i8, -1) else @as(i8, 0);
                var less_than_col_dx = if (curr_col_index < map_cols - 1) @as(i8, 2) else @as(i8, 1);
                if ((curr_col_index > 0) and
                    (map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index - 1]
                    .hasEdgeWithIndex(floorIndexToMapRowIndex(row_index + 1) * map_cols + curr_col_index)))
                    at_least_col_dx += 1;
                if ((curr_col_index < map_cols - 1) and
                    (map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index + 1]
                    .hasEdgeWithIndex(floorIndexToMapRowIndex(row_index + 1) * map_cols + curr_col_index)))
                    less_than_col_dx -= 1;
                const next_col_dx = rand.intRangeLessThan(i8, at_least_col_dx, less_than_col_dx);
                map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].insertEdge(floorIndexToMapRowIndex(row_index + 1) *
                    map_cols + @as(usize, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx)));
                map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].path_generation_index = @as(u8, @truncate(path_gen_index));
                curr_col_index = @as(u8, @intCast(@as(i8, @intCast(curr_col_index)) + next_col_dx));
            } else {
                map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].insertEdge(std.math.maxInt(usize)); // FIXME(caleb)
            }
        }
    }

    // Assign locations
    for (0..map_rows) |row_index| {
        for (0..map_cols) |col_index| {
            if (map[floorIndexToMapRowIndex(row_index) * map_cols + col_index].edgeCount() > 0)
                map[floorIndexToMapRowIndex(row_index) * map_cols + col_index].type =
                    determineLocationType(rand, map, @Vector(2, usize){ col_index, row_index });
        }
    }
}

pub fn drawMap(map: []Location, tty: std.io.tty.Config, out_stream: anytype) !void {
    try out_stream.print("\tboss floor\n", .{});
    for (0..map_rows) |row_index| {
        try out_stream.print("{d:2}. ", .{@as(u8, @intCast(map_rows - row_index - 1))});
        for (0..map_cols) |col_index| {
            try tty.setColor(out_stream, @as(std.io.tty.Color, @enumFromInt(@intFromEnum(std.io.tty.Color.red) +
                map[row_index * map_cols + col_index].path_generation_index)));
            if (map[row_index * map_cols + col_index].edgeCount() > 0) {
                try out_stream.print("{s}  ", .{@tagName(map[row_index * map_cols + col_index].type)[0..2]});
            } else {
                try out_stream.writeAll("    ");
            }
            try tty.setColor(out_stream, .reset);
        }
        try out_stream.writeByte('\n');
    }
    try out_stream.writeAll("    ");
    for (0..map_cols) |col_index| try out_stream.print("{d:1}.  ", .{col_index});
    try out_stream.writeByte('\n');
}

/// Handle those pesky CRs
fn streamAppropriately(deal_with_crs: bool, in_stream: anytype, out_stream: anytype) !void {
    if (deal_with_crs) {
        try in_stream.streamUntilDelimiter(out_stream, '\r', null);
        try in_stream.skipUntilDelimiterOrEof('\n');
    } else try in_stream.streamUntilDelimiter(out_stream, '\r', null);
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var xoshi = Xoshiro128.init(seed);
    var rand = xoshi.random();

    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();
    const tty = std.io.tty.detectConfig(stdout_file);

    var map: [map_rows * map_cols]Location = undefined;
    generateMap(rand, &map);
    try drawMap(&map, tty, stdout);

    var card_names = std.ArrayList([]const u8).init(arena);
    var cards_wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(arena);
    var cards_d_upgrade_wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(arena);
    {
        const cards_file = try std.fs.cwd().openFile(cards_csv_path, .{});
        defer cards_file.close();

        var buf: [1024]u8 = undefined;
        var cards_fbs = std.io.fixedBufferStream(&buf);
        var cards_writer = cards_fbs.writer();
        const cards_reader = cards_file.reader();

        // Figure out if lines end with '\r\n' or '\n'
        var deal_with_crs = false;
        try cards_reader.streamUntilDelimiter(cards_writer, '\n', cards_fbs.buffer.len);
        if (cards_fbs.getWritten()[try cards_fbs.getPos() - 1] == '\r') deal_with_crs = true;

        while (true) {
            cards_fbs.reset();
            streamAppropriately(deal_with_crs, cards_reader, cards_writer) catch break;
            const line = cards_fbs.getWritten();
            var card_vals = std.mem.splitSequence(u8, line, ",");

            const name = card_vals.first();
            const damage = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
            const d_upgrade_damage = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
            const block = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
            const d_upgrade_block = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
            const vulnerable = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
            const d_upgrade_vulnerable = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);

            try card_names.append(name);

            var wtf_do = std.mem.zeroes(@Vector(@intFromEnum(WTFDoDim.len), u8));
            wtf_do[@intFromEnum(WTFDoDim.damage)] = damage;
            wtf_do[@intFromEnum(WTFDoDim.block)] = block;
            wtf_do[@intFromEnum(WTFDoDim.vulnerable)] = vulnerable;
            try cards_wtf_do.append(wtf_do);

            var d_upgrade_wtf_do = std.mem.zeroes(@Vector(@intFromEnum(WTFDoDim.len), u8));
            d_upgrade_wtf_do[@intFromEnum(WTFDoDim.damage)] = d_upgrade_damage;
            d_upgrade_wtf_do[@intFromEnum(WTFDoDim.block)] = d_upgrade_block;
            d_upgrade_wtf_do[@intFromEnum(WTFDoDim.vulnerable)] = d_upgrade_vulnerable;
            try cards_d_upgrade_wtf_do.append(d_upgrade_wtf_do);
        }
    }

    std.process.cleanExit();
}
