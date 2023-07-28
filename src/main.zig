const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const mem = std.mem;
const debug = std.debug;

const Xoshiro128 = std.rand.Xoroshiro128;

const path_dens = 6;
const map_rows = 15;
const map_cols = 7;
const seed = 6;
const max_cards_in_hand = 10;
const max_monsters_per_combat = 5;
const cards_csv_path = "cards.csv";

const boss_floor_edge_index = std.math.maxInt(usize);
const neow_floor_edge_index = std.math.maxInt(usize) - 1;

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
    boss,
};

const CardType = enum {
    attack,
    skill,
    power,
    status,
    curse,
};

const MonsterType = enum {
    cultist,
};

const Monster = struct {
    type: MonsterType,
    hp: u16,
};

const WTFDoDim = enum(usize) {
    card_type,
    damage,
    block,
    vulnerable,
    ritual,

    len,
};

const Card = struct {
    id: u8,
    wtf_do: @Vector(@intFromEnum(WTFDoDim.len), u8),
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

// --- TTY functions ---
fn moveCursor(out_stream: anytype, row: usize, col: usize) !void {
    try out_stream.print("\x1b[{d};{d}H", .{ row, col });
}

fn clearScreen(out_stream: anytype) !void {
    try out_stream.writeAll("\x1b[2J");
}

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
                map[floorIndexToMapRowIndex(row_index) * map_cols + curr_col_index].insertEdge(boss_floor_edge_index);
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

const WhaleBonus = enum(u8) {
    max_hp,
    lament,
    adv_and_disadv,
    boss_relic_swap,
};

const Relic = enum {
    burning_blood,
    ring_of_the_snake,
    cracked_core,
    pure_water,
    neows_lament,
};

// NOTE(caleb): 2 for A20 potion cap. Another 2 if potion belt relic is acquired.
const max_potion_slots = 2 + 2;

const PlayerState = struct {
    hp: u8 = 68, // FIXME(caleb): Stop initializing with Ironclad hp
    max_hp: u8 = 75,
    gold: u16 = 99,
    potions: [max_potion_slots]u8 = undefined,

    relic_count: u8 = 0,
    relics: [100]Relic = undefined,

    pub fn addRelic(ps: *PlayerState, relic: Relic) void {
        debug.assert(ps.relic_count + 1 <= ps.relics.len);
        ps.relics[ps.relic_count] = relic;
        ps.relic_count += 1;
    }
};

const GameState = struct {
    floor_number: usize = 0,
    map_col_index: usize = 0,
};

fn getInputOptionIndex(output_stream: anytype, input_stream: anytype, input_fbs: *std.io.FixedBufferStream([]u8), valid_option_indices: []const u8) !?usize {
    const deal_with_crs = if (builtin.target.os.tag == .windows) true else false;
    try output_stream.writeAll("> ");
    input_fbs.reset();
    try streamAppropriately(deal_with_crs, input_stream, input_fbs.writer());
    const selected_index = fmt.parseUnsigned(u8, input_fbs.getWritten(), 10) catch return null;
    for (valid_option_indices) |option_index|
        if (option_index == selected_index)
            return selected_index;
    return null;
}

fn drawHUD(out_stream: anytype, player_state: *PlayerState, game_state: *GameState) !void {
    try moveCursor(out_stream, 0, 0);
    try out_stream.print("\x1b[1mCaleb\x1b[22m \x1b[2mThe Ironclad\x1b[22m HP: {d}/{d} gold: {d} pot,pot floor: {d} A20\n\r", .{
        player_state.hp,
        player_state.max_hp,
        player_state.gold,
        game_state.floor_number,
    });
    var relic_index: usize = 0;
    while (relic_index < player_state.relic_count) : (relic_index += 1)
        try out_stream.print("{s} ", .{@tagName(player_state.relics[relic_index])[0..2]});
    try out_stream.writeAll("\r\n");
}

fn drawMap(map: []Location, tty: std.io.tty.Config, out_stream: anytype) !void {
    try out_stream.print("\tboss floor\n", .{});
    for (0..map_rows) |row_index| {
        try out_stream.print("{d:2}. ", .{@as(u8, @intCast(map_rows - row_index))});
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
    const stdin_file = std.io.getStdIn();
    const stdout = stdout_file.writer();
    var stdin_buf: [1024]u8 = undefined;
    var stdin_fbs = std.io.fixedBufferStream(&stdin_buf);
    var stdin_writer = stdin_fbs.writer();
    const stdin = stdin_file.reader();
    const tty = std.io.tty.detectConfig(stdout_file);

    var card_names = std.ArrayList([]const u8).init(arena);
    var cards_wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(arena);
    var cards_d_upgrade_wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(arena);
    var card_map = std.StringHashMap(u8).init(arena);
    var card_count: u8 = 0;
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

            const duped_name = try arena.dupe(u8, name);
            try card_names.append(duped_name);

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

            try card_map.put(duped_name, card_count);
            card_count += 1;
        }
    }

    var player_state = PlayerState{};
    var game_state = GameState{};
    var map: [map_rows * map_cols]Location = undefined;
    generateMap(rand, &map);

    // Ironclad starter deck is 5 strikes, 4 defends, 1 bash, and 1 ascender's bane at 10+ ascention.
    var deck = std.ArrayList(Card).init(arena);
    const strike_id = card_map.get("Strike") orelse unreachable;
    const defend_id = card_map.get("Defend") orelse unreachable;
    const bash_id = card_map.get("Bash") orelse unreachable;
    const ascenders_bane_id = card_map.get("Ascender's Bane") orelse unreachable;
    for (0..5) |_| try deck.append(.{ .id = strike_id, .wtf_do = cards_wtf_do.items[strike_id] });
    for (0..4) |_| try deck.append(.{ .id = defend_id, .wtf_do = cards_wtf_do.items[defend_id] });
    try deck.append(.{ .id = bash_id, .wtf_do = cards_wtf_do.items[bash_id] });
    try deck.append(.{ .id = ascenders_bane_id, .wtf_do = cards_wtf_do.items[ascenders_bane_id] });

    // Starter relic
    player_state.relics[0] = Relic.burning_blood;
    player_state.relic_count += 1;

    while (true) { // Game loop
        try clearScreen(stdout);
        try moveCursor(stdout, 0, 0);
        try drawHUD(stdout, &player_state, &game_state);

        const location_type = if (game_state.floor_number % 15 != 0)
            map[floorIndexToMapRowIndex(game_state.floor_number - 1) * map_cols + game_state.map_col_index].type
        else if (game_state.floor_number == 0)
            LocationType.event
        else
            LocationType.boss;

        switch (location_type) {
            .monster, .elite, .boss => {
                var draw_pile = std.ArrayList(u8).init(arena);
                for (deck.items) |card| try draw_pile.append(card.id);
                rand.shuffle(u8, draw_pile.items);

                var hand: [max_cards_in_hand]u8 = undefined;
                for (&hand) |*card_index| card_index.* = 0;
                var cards_in_hand: u8 = 0;

                var discard_pile = std.ArrayList(usize).init(arena);
                _ = discard_pile;

                var monsters_in_combat: [max_monsters_per_combat]Monster = undefined;
                var n_monsters_in_encouter = @as(u8, 1);

                //TODO(caleb): 50-56 is the valid range for a cultist's hp
                monsters_in_combat[0] = .{ .type = .cultist, .hp = 56 };

                var turn_number: usize = 0;
                while (true) : (turn_number += 1) { // Combat loop
                    for (monsters_in_combat[0..n_monsters_in_encouter]) |monster| {
                        switch (monster.type) {
                            .cultist => {
                                if (turn_number == 0) { // Incantation: gain strength every turn
                                    // TODO(caleb): cast ritual
                                }
                            },
                        }
                    }

                    // Draw some cards
                    while (cards_in_hand < 5) : (cards_in_hand += 1) {

                        // TODO(caleb): Shuffle discard pile back into draw pile

                        const card_index = draw_pile.pop();
                        hand[cards_in_hand] = card_index;
                    }

                    for (0..cards_in_hand) |hand_index| try stdout.print("{d: ^4}", .{hand_index});
                    try stdout.writeByte('\n');
                    for (hand[0..cards_in_hand]) |card_index|
                        try stdout.print("{s},", .{card_names.items[card_index][0..3]});
                    try stdout.writeByte('\n');

                    // Test fight with cultist
                    try stdout.writeAll("> ");
                    try streamAppropriately(false, stdin, stdin_writer);
                    // std.debug.print("{d}.) {s} \n", .{stdin_fbs.getWritten()});

                    // TODO(caleb): Handle selecting and playing card.
                }
            },
            .event => {
                if (game_state.floor_number == 0) { // Whale bonus
                    // NOTE(caleb): Map is useful when choosing a whale bonus.
                    try clearScreen(stdout);
                    try moveCursor(stdout, 0, 0);
                    try drawHUD(stdout, &player_state, &game_state);
                    try drawMap(&map, tty, stdout);

                    const option_strs = &[_][]const u8{
                        "Max HP +8",
                        "Enemies in the next three combat will have one health.",
                    };
                    while (true) {
                        for (option_strs, 0..) |option_str, option_str_index|
                            try stdout.print("{d}.) {s}\n", .{ option_str_index, option_str });
                        const option_index = (try getInputOptionIndex(stdout, stdin, &stdin_fbs, &[_]u8{ 0, 1 })) orelse continue;
                        const whale_bonus = @as(WhaleBonus, @enumFromInt(option_index));
                        switch (whale_bonus) {
                            .max_hp => {
                                player_state.max_hp += 8;
                                player_state.hp += 8;
                            },
                            .lament => player_state.addRelic(.neows_lament),
                            else => unreachable,
                        }
                        break;
                    }
                } else unreachable;
            },
            .rest => unreachable,
            .merchant => unreachable,
            .treasure => unreachable,
        }

        // Finished doing location stuff decide where to go now!
        try clearScreen(stdout);
        try moveCursor(stdout, 0, 0);
        try drawHUD(stdout, &player_state, &game_state);
        try drawMap(&map, tty, stdout);

        var valid_col_indices: [map_cols]u8 = undefined;
        var valid_col_indices_count: u8 = 0;
        if (game_state.floor_number % 15 != 0) {
            var at_least_col_dx = if (game_state.map_col_index > 0) @as(i8, -1) else @as(i8, 0);
            var less_than_col_dx = if (game_state.map_col_index < map_cols - 1) @as(i8, 2) else @as(i8, 1);
            var d_col_index: i8 = at_least_col_dx;
            while (d_col_index < less_than_col_dx) : (d_col_index += 1) {
                if (map[floorIndexToMapRowIndex(game_state.floor_number - 1) * map_cols + game_state.map_col_index]
                    .hasEdgeWithIndex(floorIndexToMapRowIndex(game_state.floor_number) * map_cols +
                    @as(u8, @intCast(@as(i8, @intCast(game_state.map_col_index)) + d_col_index))))
                {
                    valid_col_indices[valid_col_indices_count] = @as(u8, @intCast(@as(i8, @intCast(game_state.map_col_index)) + d_col_index));
                    valid_col_indices_count += 1;
                }
            }
        } else if (game_state.floor_number == 0) {
            for (0..map_cols) |col_index| {
                if (map[(map_rows - 1) * map_cols + col_index].edgeCount() > 0) {
                    valid_col_indices[valid_col_indices_count] = @as(u8, @truncate(col_index));
                    valid_col_indices_count += 1;
                }
            }
        } else { // Only option is boss fight
            valid_col_indices[valid_col_indices_count] = 0;
            valid_col_indices_count = 1;
        }
        while (true) {
            try stdout.print("{d}\n", .{valid_col_indices[0..valid_col_indices_count]});
            const selected_index = (try getInputOptionIndex(
                stdout,
                stdin,
                &stdin_fbs,
                valid_col_indices[0..valid_col_indices_count],
            )) orelse continue;
            game_state.floor_number += 1;
            game_state.map_col_index = selected_index;
            break;
        }
    }

    std.process.cleanExit();
}
