const Self = @This();

pub const Type = enum {
    monster,
    event,
    elite,
    rest,
    merchant,
    treasure,
    boss,
};

edge_indices: [3]?usize = [_]?usize{ null, null, null },
type: Type = undefined,
path_generation_index: u8 = undefined,

pub inline fn insertEdge(loc: *Self, target_index: usize) void {
    for (&loc.edge_indices) |*edge_index| {
        if (edge_index.* == null) {
            edge_index.* = target_index;
        }
    }
}

pub inline fn edgeCount(loc: *const Self) usize {
    var result: usize = 0;
    for (loc.edge_indices) |edge_index| {
        if (edge_index != null) result += 1;
    }
    return result;
}

pub inline fn hasEdgeWithIndex(loc: *const Self, target_index: usize) bool {
    for (loc.edge_indices) |edge_index|
        if (edge_index != null and edge_index == target_index) return true;
    return false;
}
