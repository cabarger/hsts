const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const mem = std.mem;
const debug = std.debug;

const Cards = @import("Cards.zig");
const Map = @import("Map.zig");
const Location = @import("Location.zig");
const Xoshiro128 = std.rand.Xoroshiro128;

const seed = 6;
const max_cards_in_hand = 10;
const max_monsters_per_combat = 5;
const cards_csv_path = "cards.csv";

// Temp. homes for some of these guys --------------------------------------------------------------

const Monster = struct {
    pub const Type = enum {
        cultist,
    };
    type: Type,
    hp: u16,
};

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

const PlayerState = struct {
    hp: u8,
    max_hp: u8,
    gold: u16,
    /// NOTE(caleb): 2 for A20 potion cap. Another 2 if potion belt relic is acquired.
    potions: [2 + 2]u8 = undefined,
    relic_count: u8 = 0,
    relics: [100]Relic = undefined,

    pub fn addRelic(ps: *PlayerState, relic: Relic) void {
        debug.assert(ps.relic_count + 1 <= ps.relics.len);
        ps.relics[ps.relic_count] = relic;
        ps.relic_count += 1;
    }
};

const GameState = struct {
    floor_number: u8 = 0,
    map_col_index: u8 = 0,
};

// Drawing functions ------------------------------------------------------------------------------

fn moveCursor(out_stream: anytype, row: usize, col: usize) !void {
    try out_stream.print("\x1b[{d};{d}H", .{ row, col });
}

fn clearScreen(out_stream: anytype) !void {
    try out_stream.writeAll("\x1b[2J");
}

/// Draws and input prompt. Returning a non-null value when user provides value
/// in 'valid_option_indices'.
fn getInputOptionIndex(
    output_stream: anytype,
    input_stream: anytype,
    input_fbs: *std.io.FixedBufferStream([]u8),
    valid_option_indices: []const u8,
) !?usize {
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
    for (0..Map.rows) |row_index| {
        try out_stream.print("{d:2}. ", .{@as(u8, @intCast(Map.rows - row_index))});
        for (0..Map.cols) |col_index| {
            try tty.setColor(out_stream, @as(std.io.tty.Color, @enumFromInt(@intFromEnum(std.io.tty.Color.red) +
                map[row_index * Map.cols + col_index].path_generation_index)));
            if (map[row_index * Map.cols + col_index].edgeCount() > 0) {
                try out_stream.print("{s}  ", .{@tagName(map[row_index * Map.cols + col_index].type)[0..2]});
            } else {
                try out_stream.writeAll("    ");
            }
            try tty.setColor(out_stream, .reset);
        }
        try out_stream.writeByte('\n');
    }
    try out_stream.writeAll("    ");
    for (0..Map.cols) |col_index| try out_stream.print("{d:1}.  ", .{col_index});
    try out_stream.writeByte('\n');
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

    var cards = Cards.init(arena);
    defer cards.deinit();
    try cards.readCSV(cards_csv_path);

    var player_state = PlayerState{ // FIXME(caleb): Stop initializing with Ironclad hp
        .hp = 68,
        .max_hp = 75,
        .gold = 99,
    };
    var game_state = GameState{};
    var map = Map{};
    map.generate(rand);

    // Starter relic
    player_state.addRelic(.burning_blood);

    // Ironclad starter deck is 5 strikes, 4 defends, 1 bash, and 1 ascender's bane at 10+ ascention.
    var deck = std.ArrayList(Cards.Card).init(arena);
    const strike_id = cards.map.get("Strike") orelse unreachable;
    const defend_id = cards.map.get("Defend") orelse unreachable;
    const bash_id = cards.map.get("Bash") orelse unreachable;
    const ascenders_bane_id = cards.map.get("Ascender's Bane") orelse unreachable;
    for (0..5) |_| try deck.append(.{ .id = strike_id, .wtf_do = cards.wtf_do.items[strike_id] });
    for (0..4) |_| try deck.append(.{ .id = defend_id, .wtf_do = cards.wtf_do.items[defend_id] });
    try deck.append(.{ .id = bash_id, .wtf_do = cards.wtf_do.items[bash_id] });
    try deck.append(.{ .id = ascenders_bane_id, .wtf_do = cards.wtf_do.items[ascenders_bane_id] });

    while (true) { // Game loop
        try clearScreen(stdout);
        try moveCursor(stdout, 0, 0);
        try drawHUD(stdout, &player_state, &game_state);

        const location_type: Location.Type = if ((game_state.floor_number % @as(u8, Map.rows)) != 0)
            map.locationFromFloorAndColIndex(game_state.floor_number - 1, game_state.map_col_index).type
        else if (game_state.floor_number == @as(u8, 0)) .event else .boss;

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
                        try stdout.print("{s},", .{cards.names.items[card_index][0..3]});
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
                    try drawMap(&map.location_nodes, tty, stdout);

                    const option_strs = &[_][]const u8{
                        "Max HP +8",
                        "Enemies in the next three combat will have one health.",
                    };
                    while (true) {
                        for (option_strs, 0..) |option_str, option_str_index|
                            try stdout.print("{d}.) {s}\n", .{ option_str_index, option_str });
                        const option_index = (try getInputOptionIndex(
                            stdout,
                            stdin,
                            &stdin_fbs,
                            &[_]u8{ 0, 1 },
                        )) orelse continue;
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
        try drawMap(&map.location_nodes, tty, stdout);

        var valid_col_indices: [Map.cols]u8 = undefined;
        var valid_col_indices_count: u8 = 0;
        if (game_state.floor_number % 15 != 0) {
            var at_least_col_dx = if (game_state.map_col_index > 0) @as(i8, -1) else @as(i8, 0);
            var less_than_col_dx = if (game_state.map_col_index < Map.cols - 1) @as(i8, 2) else @as(i8, 1);
            var d_col_index: i8 = at_least_col_dx;
            while (d_col_index < less_than_col_dx) : (d_col_index += 1) {
                if (map.locationFromFloorAndColIndex(game_state.floor_number - 1, game_state.map_col_index)
                    .hasEdgeWithIndex(Map.floorIndexToMapRowIndex(game_state.floor_number) * Map.cols +
                    @as(u8, @intCast(@as(i8, @intCast(game_state.map_col_index)) + d_col_index))))
                {
                    valid_col_indices[valid_col_indices_count] =
                        @as(u8, @intCast(@as(i8, @intCast(game_state.map_col_index)) + d_col_index));
                    valid_col_indices_count += 1;
                }
            }
        } else if (game_state.floor_number == 0) {
            for (0..Map.cols) |col_index| {
                if (map.location_nodes[(Map.rows - 1) * Map.cols + col_index].edgeCount() > 0) {
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
            game_state.map_col_index = @as(u8, @truncate(selected_index));
            break;
        }
    }

    std.process.cleanExit();
}

/// Handle those pesky CRs
fn streamAppropriately(deal_with_crs: bool, in_stream: anytype, out_stream: anytype) !void {
    if (deal_with_crs) {
        try in_stream.streamUntilDelimiter(out_stream, '\r', null);
        try in_stream.skipUntilDelimiterOrEof('\n');
    } else try in_stream.streamUntilDelimiter(out_stream, '\r', null);
}
