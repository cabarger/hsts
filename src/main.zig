const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const mem = std.mem;
const debug = std.debug;
const time = std.time;
const windows = std.os.windows;

const art = @import("art.zig");
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

const pane_row_offset = 3;
var pane_rows = @as(usize, 0);
var pane_cols = @as(usize, 0);

const portrait_padding = 2;

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
    max_hp: u16,
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

const GameMode = enum {
    overlay, // i.e things like map, draw pile, discard pile...
    nav,
    combat,
    event,
    merchant,
    rest,
    treasure,
};

const Overlay = enum {
    map,
};

const CardHandle = struct {
    const DeckType = enum {
        perm,
        tmp,
    };
    deck_type: DeckType,
    index: u8,
};

const GameState = struct {
    const Self = @This();

    floor_number: u8 = 0,
    map_col_index: u8 = 0,
    /// NOTE(caleb): Used to determine which encounter pool is used.
    encounters_this_act: u8 = 0,
    turn_number: u8 = 0,
    did_start_of_turn_stuff: bool = false,
    selected_card_index: ?u8 = null,
    target_index: ?u8 = null,
    hand: [max_cards_in_hand]CardHandle = undefined,
    cards_in_hand: u8 = 0,
    draw_pile: std.ArrayList(CardHandle) = undefined,
    discard_pile: std.ArrayList(CardHandle) = undefined,
    exahust_pile: std.ArrayList(CardHandle) = undefined,
    monsters_in_combat: [max_monsters_per_combat]Monster = undefined,
    n_monsters_in_combat: u8 = 0,
    mode: GameMode,
    prev_mode: GameMode = undefined,
    overlay: Overlay = undefined,
    energy: u8 = 0,
    base_energy: u8 = 3,
    hp: u16,
    max_hp: u16,
    gold: u16,
    /// NOTE(caleb): 2 for A20 potion cap. Another 2 if potion belt relic is acquired.
    potions: [2 + 2]u8 = undefined,
    relic_count: u8 = 0,
    relics: [100]Relic = undefined,

    deck: Deck = undefined,
    tmp_deck: Deck = undefined,

    pub fn addRelic(self: *Self, relic: Relic) void {
        debug.assert(self.relic_count + 1 <= self.relics.len);
        self.relics[self.relic_count] = relic;
        self.relic_count += 1;
    }

    pub fn initCombat(self: *Self, rng: std.rand.Random) !void {
        for (0..self.deck.cards.items.len) |card_index| try self.draw_pile.append(CardHandle{
            .index = @intCast(card_index),
            .deck_type = .perm,
        });
        rng.shuffle(CardHandle, self.draw_pile.items);
        for (&self.hand) |*card_handle| card_handle.* = .{ .index = 0, .deck_type = undefined };

        // TODO(caleb): other acts
        var encounter: Act1Encounter =
            if (self.encounters_this_act < 3)
            @enumFromInt(rng.weightedIndex(f32, act1_encounter_distribution[0..act1_easy_encounter_count]))
        else
            @enumFromInt(rng.weightedIndex(f32, act1_encounter_distribution[act1_easy_encounter_count..]) +
                act1_easy_encounter_count);
        switch (encounter) {
            .cultist, .jaw_worm, .two_louses, .small_slimes => {
                // 50-56 is the valid range for a cultist's hp
                self.monsters_in_combat[0] = .{ .type = .cultist, .hp = 50, .max_hp = 50 };
                // self.monsters_in_combat[0].hp += rng.uintLessThan(u16, 7);
                self.n_monsters_in_combat += 1;
            },
            // .jaw_worm => unreachable,
            // .two_louses => unreachable,
            // .small_slimes => unreachable,
            else => unreachable,
        }
    }

    pub fn drawCards(self: *Self, rng: std.rand.Random) !void {
        const base_card_draw = 5;
        var cards_drawn_this_turn: u8 = 0;
        while (cards_drawn_this_turn < base_card_draw and self.cards_in_hand + 1 < max_cards_in_hand) {
            if (self.draw_pile.items.len == 0) {
                if (self.discard_pile.items.len == 0) break;
                rng.shuffle(CardHandle, self.discard_pile.items);
                for (self.discard_pile.items, 0..) |card_handle, card_index|
                    try self.draw_pile.insert(card_index, card_handle);
                self.discard_pile.clearRetainingCapacity();
            }
            self.hand[self.cards_in_hand] = self.draw_pile.pop();

            self.cards_in_hand += 1;
            cards_drawn_this_turn += 1;
        }
    }

    pub fn cardFromHandle(self: *Self, card_handle: CardHandle) Cards.Card {
        const card: Cards.Card = if (card_handle.deck_type == .perm)
            self.deck.cards.items[card_handle.index]
        else
            self.tmp_deck.cards.items[card_handle.index];
        return card;
    }

    pub fn cardTypeFromHandle(self: *Self, card_handle: CardHandle) Cards.Type {
        return @as(Cards.Type, @enumFromInt(self.cardFromHandle(card_handle).wtf_do[@intFromEnum(Cards.WTFDoDim.card_type)]));
    }

    pub fn isPlayableCard(self: *Self, card_handle: CardHandle) bool {
        const card_type = self.cardTypeFromHandle(card_handle);
        if (card_type != .status and card_type != .curse) // TODO(caleb): relics that allow you to play these cards.
            return true;
        return false;
    }

    pub fn endTurn(self: *Self) void {
        _ = self;
    }
};

// Drawing functions ------------------------------------------------------------------------------

fn moveCursor(output_stream: anytype, row: usize, col: usize) !void {
    try output_stream.print("\x1b[{d};{d}H", .{ row, col });
}

fn clearPane(output_stream: anytype) !void {
    var pane_row = @as(usize, 0);
    while (pane_row < pane_rows) : (pane_row += 1) {
        try moveCursor(output_stream, pane_row + pane_row_offset, 0);
        try clearLine(output_stream);
    }
}

fn clearScreen(output_stream: anytype) !void {
    try output_stream.writeAll("\x1b[2J");
}

fn clearLine(output_stream: anytype) !void {
    try output_stream.writeAll("\x1b[2K");
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

fn drawHUD(output_stream: anytype, gs: *GameState) !void {
    try output_stream.print("\x1b[1mCaleb\x1b[22m \x1b[2mThe Ironclad\x1b[22m HP: {d}/{d} gold: {d} pot,pot floor: {d} A20\n\r", .{
        gs.hp,
        gs.max_hp,
        gs.gold,
        gs.floor_number,
    });
    var relic_index: usize = 0;
    while (relic_index < gs.relic_count) : (relic_index += 1)
        try output_stream.print("{s} ", .{@tagName(gs.relics[relic_index])[0..2]});
    try output_stream.writeAll("\r\n");
}

fn drawMap(gs: *GameState, map: []Location, tty: std.io.tty.Config, output_stream: anytype) !void {
    try moveCursor(output_stream, pane_row_offset, 0);
    try output_stream.print("\tboss floor\n", .{});
    for (0..Map.rows) |row_index| {
        try tty.setColor(output_stream, .reset);
        try output_stream.print("{d:2}. ", .{@as(u8, @intCast(Map.rows - row_index))});
        for (0..Map.cols) |col_index| {
            const location_color: std.io.tty.Color = @enumFromInt(@intFromEnum(std.io.tty.Color.red) +
                map[row_index * Map.cols + col_index].path_generation_index);
            try tty.setColor(output_stream, location_color);
            if (map[row_index * Map.cols + col_index].edgeCount() > 0) {
                if ((col_index == gs.map_col_index) and (Map.rows - row_index == gs.floor_number))
                    try tty.setColor(output_stream, .bold);
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

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var xoshi = Xoshiro128.init(seed);
    var rng = xoshi.random();

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

    var frame_input = @as(u8, 0);

    var cards = Cards.init(arena);
    defer cards.deinit();
    try cards.readCSV(cards_csv_path);

    var gs = GameState{
        .hp = 68,
        .max_hp = 75,
        .gold = 99,
        .mode = .event,
    };
    gs.draw_pile = std.ArrayList(CardHandle).init(arena);
    gs.discard_pile = std.ArrayList(CardHandle).init(arena);
    gs.exahust_pile = std.ArrayList(CardHandle).init(arena);
    gs.deck = Deck.init(arena);
    gs.tmp_deck = Deck.init(arena);

    var map = Map{};
    map.generate(rng);

    // Starter relic
    gs.addRelic(.burning_blood);

    // Ironclad starter deck is 5 strikes, 4 defends, 1 bash, and 1 ascender's bane at 10+ ascention.
    const strike_id = cards.map.get("Strike") orelse unreachable;
    const defend_id = cards.map.get("Defend") orelse unreachable;
    const bash_id = cards.map.get("Bash") orelse unreachable;
    const ascenders_bane_id = cards.map.get("Ascender's Bane") orelse unreachable;
    for (0..5) |_| try gs.deck.addCard(&cards, strike_id);
    for (0..4) |_| try gs.deck.addCard(&cards, defend_id);
    try gs.deck.addCard(&cards, bash_id);
    try gs.deck.addCard(&cards, ascenders_bane_id);

    try clearScreen(stdout);

    var max_rows: usize = undefined;
    var max_cols: usize = undefined;
    console.maxRowCol(&max_rows, &max_cols); // NOTE(caleb): ReadConsoleInput and check for resize event?
    debug.assert(max_cols >= (art.portrait_cols + portrait_padding) * 6);
    pane_rows = @as(usize, @intFromFloat(0.75 * @as(f32, @floatFromInt(max_rows))));
    pane_cols = max_cols;

    while (true) {

        // Update ------------------------------------------------------------------------------

        switch (frame_input) { // Game mode agnostic inputs.
            'm' => {
                if (gs.mode != .nav) {
                    if (gs.mode != .overlay) {
                        gs.prev_mode = gs.mode;
                        gs.mode = .overlay;
                    } else gs.mode = gs.prev_mode;
                }
            },
            else => {},
        }

        switch (gs.mode) {
            .overlay => {}, // NOTE(caleb): Nothing to update
            .nav => {
                var valid_col_indices: [Map.cols]u8 = undefined;
                var valid_col_indices_count: u8 = 0;
                if ((gs.floor_number % Map.rows) != 0) {
                    var at_least_col_dx = if (gs.map_col_index > 0) @as(i8, -1) else @as(i8, 0);
                    var less_than_col_dx = if (gs.map_col_index < Map.cols - 1) @as(i8, 2) else @as(i8, 1);
                    var d_col_index: i8 = at_least_col_dx;
                    while (d_col_index < less_than_col_dx) : (d_col_index += 1) {
                        if (map.locationFromFloorAndColIndex(gs.floor_number - 1, gs.map_col_index)
                            .hasEdgeWithIndex(Map.floorIndexToMapRowIndex(gs.floor_number) * Map.cols +
                            @as(u8, @intCast(@as(i8, @intCast(gs.map_col_index)) + d_col_index))))
                        {
                            valid_col_indices[valid_col_indices_count] =
                                @as(u8, @intCast(@as(i8, @intCast(gs.map_col_index)) + d_col_index));
                            valid_col_indices_count += 1;
                        }
                    }
                } else if (gs.floor_number == 0) {
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

                const option_index: ?u8 = fmt.charToDigit(frame_input, 10) catch null;
                if (option_index != null) {
                    var provided_valid_index = false;
                    for (valid_col_indices[0..valid_col_indices_count]) |valid_index| {
                        if (option_index == valid_index) {
                            provided_valid_index = true;
                            break;
                        }
                    }
                    if (provided_valid_index) {
                        gs.floor_number += 1;
                        gs.map_col_index = @as(u8, @truncate(option_index.?));
                        const location_type: Location.Type = if ((gs.floor_number % @as(u8, Map.rows)) != 0)
                            map.locationFromFloorAndColIndex(gs.floor_number - 1, gs.map_col_index).type
                        else if (gs.floor_number == @as(u8, 0)) .event else .boss;
                        switch (location_type) {
                            .monster, .elite, .boss => {
                                gs.mode = .combat;
                                try gs.initCombat(rng);

                                frame_input = 0;
                                continue; // NOTE(caleb): goto combat
                            },
                            .event => gs.mode = .event,
                            .rest => unreachable,
                            .merchant => unreachable,
                            .treasure => unreachable,
                        }
                    }
                }
            },
            .combat => {
                if (!gs.did_start_of_turn_stuff) { // Handle start of turn
                    try gs.drawCards(rng);
                    // NOTE(caleb): ^This^ and probably 30 other things.
                    gs.did_start_of_turn_stuff = true;
                }
                const option_index: ?u8 = fmt.charToDigit(frame_input, 10) catch null;
                if (option_index != null) {
                    if (option_index.? < gs.cards_in_hand) {
                        // If a card is selected already attempt to play the card
                        if (gs.selected_card_index != null and option_index.? == gs.selected_card_index.?) {
                            // TODO(caleb): Energy....
                            const card_to_play = gs.hand[option_index.?];

                            if (gs.isPlayableCard(gs.hand[option_index.?])) {
                                const card_type = gs.cardTypeFromHandle(gs.hand[option_index.?]);

                                // NOTE(caleb): Need to validate
                                if (card_type == .attack and gs.target_index == null) { // NOTE(caleb): Attacks can be ambigous so a target will need to be supplied.
                                    frame_input = 0;
                                    continue;
                                }

                                // Clear selected card
                                gs.selected_card_index = null;

                                // Remove the card from hand
                                gs.cards_in_hand -= 1;
                                if (gs.cards_in_hand > 0)
                                    gs.hand[option_index.?] = gs.hand[gs.cards_in_hand];

                                // TODO(caleb): discard_pile or exhaust_pile
                                try gs.discard_pile.append(gs.hand[option_index.?]);
                            }

                            _ = card_to_play;
                        } else gs.selected_card_index = option_index.?; // Select the card
                    }
                } else if (frame_input == 'e') {
                    // End turn stuff

                    // Discard cards in hand
                    for (0..gs.cards_in_hand) |card_index|
                        try gs.discard_pile.insert(card_index, gs.hand[card_index]);
                    gs.cards_in_hand = 0;

                    // Monster turn
                    for (gs.monsters_in_combat[0..gs.n_monsters_in_combat]) |monster| {
                        switch (monster.type) {
                            .cultist => {
                                if (gs.turn_number == 0) { // Incantation: gain strength every turn
                                    // TODO(caleb): cast ritual
                                }
                            },
                            else => unreachable,
                        }
                    }
                    gs.did_start_of_turn_stuff = false; // End turn
                    gs.turn_number += 1;

                    frame_input = 0;
                    continue;
                }
            },
            .event => {
                if (gs.floor_number == 0) { // Whale bonus
                    const option_index: ?u8 = fmt.charToDigit(frame_input, 10) catch null;
                    if (option_index != null) {
                        const whale_bonus = @as(WhaleBonus, @enumFromInt(option_index.?));
                        switch (whale_bonus) {
                            .max_hp => {
                                gs.max_hp += 8;
                                gs.hp += 8;
                            },
                            .lament => gs.addRelic(.neows_lament),
                            else => unreachable,
                        }
                        gs.mode = .nav;
                    }
                } else unreachable;
            },
            else => unreachable,
        }

        // Draw ------------------------------------------------------------------------------

        try moveCursor(stdout, 0, 0);
        try clearLine(stdout);
        try drawHUD(stdout, &gs);

        switch (gs.mode) {
            .overlay => {
                switch (gs.overlay) {
                    .map => {
                        try clearPane(stdout);
                        try drawMap(&gs, &map.location_nodes, tty, stdout);
                    },
                }
            },
            .event => {
                if (gs.floor_number == 0) { // Whale bonus
                    try clearPane(stdout);
                    try moveCursor(stdout, pane_row_offset, 0);
                    const option_strs = &[_][]const u8{
                        "Max HP +8",
                        "Enemies in the next three combat will have one health.",
                    };
                    for (option_strs, 0..) |option_str, option_str_index|
                        try stdout.print("{d}.) {s}\n", .{ option_str_index, option_str });
                } else unreachable;
            },
            .combat => {
                try clearPane(stdout);
                try moveCursor(stdout, pane_row_offset, 0);

                // Character
                try stdout.writeAll(art.ironclad); // TODO(caleb): Do this on a character basis
                try stdout.writeAll("\n\n");
                var num_bars_to_color_red: usize = @intFromFloat(@as(f32, @floatFromInt(gs.hp)) / @as(f32, @floatFromInt(gs.max_hp)) * @as(f32, art.portrait_cols));
                for (0..art.portrait_cols) |hp_bar_col_index| {
                    if (hp_bar_col_index <= num_bars_to_color_red) {
                        try tty.setColor(stdout, .red);
                    } else try tty.setColor(stdout, .white);
                    try stdout.writeAll("█");
                }
                try tty.setColor(stdout, .reset);

                // Enemies
                // TODO(caleb): Draw enemy move intent.
                for (gs.monsters_in_combat[0..gs.n_monsters_in_combat], 0..) |monster, monster_index| {
                    var portrait_iter = mem.splitSequence(u8, art.cultist, "\n");
                    var portrait_line: ?[]const u8 = portrait_iter.first();
                    const col_offset = (monster_index + 1) * (art.portrait_cols + portrait_padding);
                    for (0..art.portrait_rows) |portrait_row_index| {
                        try moveCursor(stdout, pane_row_offset + portrait_row_index, col_offset);
                        try stdout.writeAll(portrait_line.?);
                        portrait_line = portrait_iter.next();
                    }
                    try moveCursor(stdout, pane_row_offset + art.portrait_rows + 1, col_offset);
                    num_bars_to_color_red = @intFromFloat(@as(f32, @floatFromInt(monster.max_hp)) / @as(f32, @floatFromInt(monster.max_hp)) * @as(f32, art.portrait_cols));
                    for (0..art.portrait_cols) |hp_bar_col_index| {
                        if (hp_bar_col_index <= num_bars_to_color_red) {
                            try tty.setColor(stdout, .red);
                        } else try tty.setColor(stdout, .white);
                        try stdout.writeAll("█");
                    }
                    try tty.setColor(stdout, .reset);
                }

                // Energy
                try stdout.print("\n\n{d}/{d}\n\n\n", .{ gs.energy, gs.base_energy });

                // Cards
                var cursor_row: usize = undefined;
                var cursor_col: usize = undefined;
                console.cursorRowCol(&cursor_row, &cursor_col); // NOTE(caleb): Don't care what cursor_col is
                cursor_col = 1;
                try moveCursor(stdout, cursor_row, cursor_col);
                for (gs.hand[0..gs.cards_in_hand], 0..) |card_handle, card_index| {
                    var row_offset: isize = 0;
                    if (gs.selected_card_index != null and card_index == gs.selected_card_index.?)
                        row_offset -= 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.writeAll("------");
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.print("|{s}|", .{if (card_handle.deck_type == .perm) cards.names.items[gs.deck.cards.items[card_handle.index].id][0..4] else cards.names.items[gs.tmp_deck.cards.items[card_handle.index].id][0..4]});
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.writeAll("|----|");
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.print("|{s}|", .{if (card_handle.deck_type == .perm) @tagName(@as(Cards.Type, @enumFromInt(gs.deck.cards.items[card_handle.index].wtf_do[@intFromEnum(Cards.WTFDoDim.card_type)])))[0..4] else @tagName(@as(Cards.Type, @enumFromInt(gs.tmp_deck.cards.items[card_handle.index].wtf_do[@intFromEnum(Cards.WTFDoDim.card_type)])))[0..4]});
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.print("|{d}   |", .{if (card_handle.deck_type == .perm) gs.deck.cards.items[card_handle.index].wtf_do[@intFromEnum(Cards.WTFDoDim.cost)] else gs.tmp_deck.cards.items[card_handle.index].wtf_do[@intFromEnum(Cards.WTFDoDim.cost)]});
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.writeAll("------");
                    row_offset += 1;
                    try moveCursor(stdout, @as(usize, @intCast(@as(isize, @intCast(cursor_row)) + row_offset)), cursor_col);
                    try stdout.print("{d: ^6}\n", .{card_index});

                    cursor_col += 8;
                    try moveCursor(stdout, cursor_row, cursor_col);
                }

                try moveCursor(stdout, pane_rows, pane_cols); // BANISH THE CURSOR

            },
            .nav => {
                try clearPane(stdout);
                try drawMap(&gs, &map.location_nodes, tty, stdout);

                var valid_col_indices: [Map.cols]u8 = undefined;
                var valid_col_indices_count: u8 = 0;
                if ((gs.floor_number % Map.rows) != 0) {
                    var at_least_col_dx = if (gs.map_col_index > 0) @as(i8, -1) else @as(i8, 0);
                    var less_than_col_dx = if (gs.map_col_index < Map.cols - 1) @as(i8, 2) else @as(i8, 1);
                    var d_col_index: i8 = at_least_col_dx;
                    while (d_col_index < less_than_col_dx) : (d_col_index += 1) {
                        if (map.locationFromFloorAndColIndex(gs.floor_number - 1, gs.map_col_index)
                            .hasEdgeWithIndex(Map.floorIndexToMapRowIndex(gs.floor_number) * Map.cols +
                            @as(u8, @intCast(@as(i8, @intCast(gs.map_col_index)) + d_col_index))))
                        {
                            valid_col_indices[valid_col_indices_count] =
                                @as(u8, @intCast(@as(i8, @intCast(gs.map_col_index)) + d_col_index));
                            valid_col_indices_count += 1;
                        }
                    }
                } else if (gs.floor_number == 0) {
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
                try stdout.print("{d}\n", .{valid_col_indices[0..valid_col_indices_count]});
            },
            else => unreachable,
        }

        frame_input = try stdin.readByte(); // Read next input
    }

    std.process.cleanExit();
}
