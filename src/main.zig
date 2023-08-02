const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const mem = std.mem;
const debug = std.debug;
const time = std.time;
const windows = std.os.windows;

const Deck = @import("Deck.zig");
const Cards = @import("Cards.zig");
const Map = @import("Map.zig");
const Location = @import("Location.zig");
const Console = @import("Console.zig");
const Xoshiro128 = std.rand.Xoroshiro128;

const seed = 6;
const max_cards_in_hand = 10;
const max_monsters_per_combat = 5;
const cards_csv_path = "cards.csv";
const fps = 2;

// NOTE(caleb): Headless slay the spire will be broken into 2 distinct modes
// 1) Nearly headless mode - mode that a human can play (used for debugging)
// 2) Full headless mode - mode that a model can interact with.

// Temp. homes for some of these guys --------------------------------------------------------------

const Monster = struct {
    pub const Type = enum {
        cultist,
        jaw_worm,
        louse,
        s_acid_slime,
        s_spike_slime,
        m_acid_slime,
        m_spike_slime,
    };
    type: Type,
    hp: u16,
};

const act1_easy_encounter_count = 4;
const act1_encounter_distribution = [_]f32{
    // Easy encounters:
    0.25, // Cultist
    0.00, //0.25, // Jaw Worm
    0.00, //0.25, // 2 Louses
    0.00, //0.25, // Small slimes

    // Hard encounters:
    0.0625, // Gremlin Gang
    0.125, // Large Slime
    0.0625, // Lots of Slimes
    0.125, // Blue Slaver
    0.0625, // Red Slaver
    0.125, // 3 Louses
    0.125, // 2 Fungi Beasts
    0.09375, // Exordium Thugs
    0.09375, // Exordium Wildlife
    0.125, // Looter
};

const Act1Encounter = enum {
    cultist,
    jaw_worm,
    two_louses,
    small_slimes,
    gremlin_gang,
    large_slime,
    lots_of_slimes,
    blue_slaver,
    red_slaver,
    three_louses,
    two_fungi_beasts,
    exordium_thugs,
    exordium_wildlife,
    looter,
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
    deck: Deck = undefined,

    pub fn addRelic(ps: *PlayerState, relic: Relic) void {
        debug.assert(ps.relic_count + 1 <= ps.relics.len);
        ps.relics[ps.relic_count] = relic;
        ps.relic_count += 1;
    }
};

const GameState = struct {
    floor_number: u8 = 0,
    map_col_index: u8 = 0,
    /// NOTE(caleb): Used to determine which encounter pool is used.
    encounters_this_act: u8 = 0,
};

// Drawing functions ------------------------------------------------------------------------------

fn moveCursor(output_stream: anytype, row: usize, col: usize) !void {
    try output_stream.print("\x1b[{d};{d}H", .{ row, col });
}

fn clearScreen(output_stream: anytype) !void {
    try output_stream.writeAll("\x1b[2J");
}

/// Draws and input prompt. Returning a non-null value when user provides value
/// in 'valid_option_indices'.
fn getInputOptionIndex(
    output_stream: anytype,
    input_stream: anytype,
    input_fbs: *std.io.FixedBufferStream([]u8),
    valid_option_indices: []const u8,
) !?usize {
    try output_stream.writeAll("> ");
    // input_fbs.reset();
    _ = input_fbs;

    const byte = try input_stream.readByte();
    const selected_index = fmt.charToDigit(byte, 10) catch return null; //fmt.parseUnsigned(u8, byte, 10) catch return null;
    for (valid_option_indices) |option_index|
        if (option_index == selected_index)
            return selected_index;
    return null;
}

fn drawHUD(output_stream: anytype, player_state: *PlayerState, game_state: *GameState) !void {
    try moveCursor(output_stream, 0, 0);
    try output_stream.print("\x1b[1mCaleb\x1b[22m \x1b[2mThe Ironclad\x1b[22m HP: {d}/{d} gold: {d} pot,pot floor: {d} A20\n\r", .{
        player_state.hp,
        player_state.max_hp,
        player_state.gold,
        game_state.floor_number,
    });
    var relic_index: usize = 0;
    while (relic_index < player_state.relic_count) : (relic_index += 1)
        try output_stream.print("{s} ", .{@tagName(player_state.relics[relic_index])[0..2]});
    try output_stream.writeAll("\r\n");
}

fn drawMap(map: []Location, tty: std.io.tty.Config, output_stream: anytype) !void {
    try output_stream.print("\tboss floor\n", .{});
    for (0..Map.rows) |row_index| {
        try output_stream.print("{d:2}. ", .{@as(u8, @intCast(Map.rows - row_index))});
        for (0..Map.cols) |col_index| {
            try tty.setColor(output_stream, @as(std.io.tty.Color, @enumFromInt(@intFromEnum(std.io.tty.Color.red) +
                map[row_index * Map.cols + col_index].path_generation_index)));
            if (map[row_index * Map.cols + col_index].edgeCount() > 0) {
                try output_stream.print("{s}  ", .{@tagName(map[row_index * Map.cols + col_index].type)[0..2]});
            } else {
                try output_stream.writeAll("    ");
            }
            try tty.setColor(output_stream, .reset);
        }
        try output_stream.writeByte('\n');
    }
    try output_stream.writeAll("    ");
    for (0..Map.cols) |col_index| try output_stream.print("{d:1}.  ", .{col_index});
    try output_stream.writeByte('\n');
}

// asdf ------------------------------------------------------------------------------

fn combat(
    arena_ally: std.mem.Allocator,
    cards: *Cards,
    game_state: *GameState,
    player_state: *PlayerState,
    rand: std.rand.Random,
    output_stream: anytype,
    input_stream: anytype,
    input_fbs: *std.io.FixedBufferStream([]u8),
) !void {
    var draw_pile = std.ArrayList(u8).init(arena_ally);
    for (player_state.deck.cards.items) |card| try draw_pile.append(card.id);
    rand.shuffle(u8, draw_pile.items);

    var hand: [max_cards_in_hand]u8 = undefined;
    for (&hand) |*card_index| card_index.* = 0;
    var cards_in_hand: u8 = 0;

    var discard_pile = std.ArrayList(u8).init(arena_ally);

    var monsters_in_combat: [max_monsters_per_combat]Monster = undefined;
    var n_monsters_in_combat = @as(u8, 0);

    // TODO(caleb): other acts
    var encounter =
        if (game_state.encounters_this_act < 3)
        @as(Act1Encounter, @enumFromInt(rand.weightedIndex(f32, act1_encounter_distribution[0..act1_easy_encounter_count])))
    else
        @as(Act1Encounter, @enumFromInt(rand.weightedIndex(f32, act1_encounter_distribution[act1_easy_encounter_count..]) +
            act1_easy_encounter_count));
    switch (encounter) {
        .cultist => {
            // 50-56 is the valid range for a cultist's hp
            monsters_in_combat[0] = .{ .type = .cultist, .hp = 50 };
            monsters_in_combat[0].hp += rand.uintLessThan(u16, 7);
            n_monsters_in_combat += 1;
        },
        .jaw_worm => {},
        .two_louses => {},
        .small_slimes => {},
        else => unreachable,
    }

    var turn_number: usize = 0;
    while (true) : (turn_number += 1) {
        while (cards_in_hand < 5) : (cards_in_hand += 1) {
            if (draw_pile.items.len == 0) {
                if (discard_pile.items.len == 0) break;
                rand.shuffle(u8, discard_pile.items);
                for (discard_pile.items, 0..) |card, card_index| try draw_pile.insert(card_index, card);
            }
            const card_index = draw_pile.pop();
            hand[cards_in_hand] = card_index;
        }
        for (0..cards_in_hand) |card_index| try output_stream.print("{d: ^4}", .{card_index});
        try output_stream.writeByte('\n');
        for (hand[0..cards_in_hand]) |card_index|
            try output_stream.print("{s},", .{cards.names.items[card_index][0..3]});
        try output_stream.writeByte('\n');

        // Player turn
        while (true) {
            var valid_option_indices: [max_cards_in_hand]u8 = undefined;
            for (0..cards_in_hand) |card_index|
                valid_option_indices[card_index] = @as(u8, @intCast(card_index));
            const option_index = (try getInputOptionIndex(
                output_stream,
                input_stream,
                input_fbs,
                valid_option_indices[0..cards_in_hand],
            )) orelse {
                if (input_fbs.getWritten()[0] != 'e') // End turn
                    continue;
                break;
            };
            _ = option_index;

            break;
        }

        // Discard cards in hand
        for (0..cards_in_hand) |card_index|
            try discard_pile.insert(card_index, hand[card_index]);
        cards_in_hand = 0;

        // Monster turn
        for (monsters_in_combat[0..n_monsters_in_combat]) |monster| {
            switch (monster.type) {
                .cultist => {
                    if (turn_number == 0) { // Incantation: gain strength every turn
                        // TODO(caleb): cast ritual
                    }
                },
                else => unreachable,
            }
        }
    }
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
    _ = stdin_writer;
    const stdin = stdin_file.reader();
    const tty = std.io.tty.detectConfig(stdout_file);

    var console = Console.init(stdin_file.handle, stdout_file.handle);
    defer console.deinit();

    var cards = Cards.init(arena);
    defer cards.deinit();
    try cards.readCSV(cards_csv_path);

    var player_state = PlayerState{ // FIXME(caleb): Stop initializing with Ironclad hp
        .hp = 68,
        .max_hp = 75,
        .gold = 99,
    };
    player_state.deck = Deck.init(arena);
    defer player_state.deck.deinit();
    var game_state = GameState{};
    var map = Map{};
    map.generate(rand);

    // Starter relic
    player_state.addRelic(.burning_blood);

    // Ironclad starter deck is 5 strikes, 4 defends, 1 bash, and 1 ascender's bane at 10+ ascention.
    const strike_id = cards.map.get("Strike") orelse unreachable;
    const defend_id = cards.map.get("Defend") orelse unreachable;
    const bash_id = cards.map.get("Bash") orelse unreachable;
    const ascenders_bane_id = cards.map.get("Ascender's Bane") orelse unreachable;
    for (0..5) |_| try player_state.deck.addCard(&cards, strike_id);
    for (0..4) |_| try player_state.deck.addCard(&cards, defend_id);
    try player_state.deck.addCard(&cards, bash_id);
    try player_state.deck.addCard(&cards, ascenders_bane_id);

    while (true) { // Game loop
        const location_type: Location.Type = if ((game_state.floor_number % @as(u8, Map.rows)) != 0)
            map.locationFromFloorAndColIndex(game_state.floor_number - 1, game_state.map_col_index).type
        else if (game_state.floor_number == @as(u8, 0)) .event else .boss;
        switch (location_type) {
            .monster, .elite, .boss => {
                try combat(arena, &cards, &game_state, &player_state, rand, stdout, stdin, &stdin_fbs);
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

        // try stdout.print("{c}\n", .{stdin.readByte() catch unreachable});
    }

    std.process.cleanExit();
}

/// Handle those pesky CRs
fn streamAppropriately(deal_with_crs: bool, input_stream: anytype, output_stream: anytype) !void {
    if (deal_with_crs) {
        try input_stream.streamUntilDelimiter(output_stream, '\r', null);
        try input_stream.skipUntilDelimiterOrEof('\n');
    } else try input_stream.streamUntilDelimiter(output_stream, '\r', null);
}
