const std = @import("std");
const fmt = std.fmt;

const Self = @This();

pub const Type = enum {
    attack,
    skill,
    power,
    status,
    curse,
};

pub const WTFDoDim = enum(usize) {
    card_type,
    damage,
    block,
    vulnerable,
    ritual,
    cost,

    len,
};

pub const Card = struct {
    id: u8,
    wtf_do: @Vector(@intFromEnum(WTFDoDim.len), u8),
};

ally: std.mem.Allocator,
names: std.ArrayList([]const u8),
wtf_do: std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)), // NOTE(caleb): This is base wtf do
d_upgrade_wtf_do: std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)),
map: std.StringHashMap(u8),
count: u8 = 0,

/// Handle those pesky CRs
fn streamAppropriately(deal_with_crs: bool, in_stream: anytype, out_stream: anytype) !void {
    if (deal_with_crs) {
        try in_stream.streamUntilDelimiter(out_stream, '\r', null);
        try in_stream.skipUntilDelimiterOrEof('\n');
    } else try in_stream.streamUntilDelimiter(out_stream, '\r', null);
}

pub fn init(ally: std.mem.Allocator) Self {
    return Self{
        .ally = ally,
        .names = std.ArrayList([]const u8).init(ally),
        .wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(ally),
        .d_upgrade_wtf_do = std.ArrayList(@Vector(@intFromEnum(WTFDoDim.len), u8)).init(ally),
        .map = std.StringHashMap(u8).init(ally),
    };
}

pub fn deinit(self: *Self) void {
    self.names.deinit();
    self.wtf_do.deinit();
    self.d_upgrade_wtf_do.deinit();
    self.map.deinit();
}

pub fn readCSV(self: *Self, cards_csv_path: []const u8) !void {
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
        const card_type = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const damage = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const d_upgrade_damage = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const block = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const d_upgrade_block = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const vulnerable = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const d_upgrade_vulnerable = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        const cost = try fmt.parseUnsigned(u8, card_vals.next() orelse unreachable, 10);
        //TODO(caleb): d_upgrade_cost

        const duped_name = try self.ally.dupe(u8, name);
        try self.names.append(duped_name);

        var wtf_do = std.mem.zeroes(@Vector(@intFromEnum(WTFDoDim.len), u8));
        wtf_do[@intFromEnum(WTFDoDim.card_type)] = card_type;
        wtf_do[@intFromEnum(WTFDoDim.damage)] = damage;
        wtf_do[@intFromEnum(WTFDoDim.block)] = block;
        wtf_do[@intFromEnum(WTFDoDim.vulnerable)] = vulnerable;
        wtf_do[@intFromEnum(WTFDoDim.cost)] = cost;
        try self.wtf_do.append(wtf_do);

        var d_upgrade_wtf_do = std.mem.zeroes(@Vector(@intFromEnum(WTFDoDim.len), u8));
        d_upgrade_wtf_do[@intFromEnum(WTFDoDim.damage)] = d_upgrade_damage;
        d_upgrade_wtf_do[@intFromEnum(WTFDoDim.block)] = d_upgrade_block;
        d_upgrade_wtf_do[@intFromEnum(WTFDoDim.vulnerable)] = d_upgrade_vulnerable;
        try self.d_upgrade_wtf_do.append(d_upgrade_wtf_do);

        try self.map.put(duped_name, self.count);
        self.count += 1;
    }
}
