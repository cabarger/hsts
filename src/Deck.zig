const std = @import("std");

const Cards = @import("Cards.zig");
const Self = @This();

ally: std.mem.Allocator,
cards: std.ArrayList(Cards.Card),

pub fn init(ally: std.mem.Allocator) Self {
    return Self{
        .ally = ally,
        .cards = std.ArrayList(Cards.Card).init(ally),
    };
}

pub fn deinit(self: *Self) void {
    self.cards.deinit();
}

pub fn addCard(self: *Self, cards: *Cards, card_id: u8) !void {
    try self.cards.append(.{ .id = card_id, .wtf_do = cards.wtf_do.items[card_id] });
}
