const std = @import("std");

/// Supported CRDT types in our engine.
pub const CrdtType = enum(u8) {
    lww_register = 0x01, // Last-Write-Wins Register
    pn_counter = 0x02,   // Positive-Negative Counter
    aw_set = 0x03,       // Add-Wins Set
};

/// Metadata for an LWW (Last-Write-Wins) Register.
pub const LwwMetadata = struct {
    timestamp: i64,
    node_id: u32,

    pub fn supersedes(self: LwwMetadata, other: LwwMetadata) bool {
        if (self.timestamp > other.timestamp) return true;
        if (self.timestamp < other.timestamp) return false;
        // Tie-break with node_id
        return self.node_id > other.node_id;
    }
};

/// A single cell in a row.
pub const Cell = union(CrdtType) {
    lww_register: struct {
        value: []u8,
        metadata: LwwMetadata,
    },
    pn_counter: struct {
        // Map of node_id -> current count for that node
        counts: std.AutoHashMap(u32, i64),
        // Map of node_id -> highest timestamp seen from that node
        timestamps: std.AutoHashMap(u32, i64),
    },
    aw_set: struct {
        // Map of value -> set of (timestamp, node_id) "dots"
        elements: std.StringHashMap(std.ArrayList(LwwMetadata)),
    },

    pub fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .lww_register => |reg| allocator.free(reg.value),
            .pn_counter => |*cnt| {
                cnt.counts.deinit();
                cnt.timestamps.deinit();
            },
            .aw_set => |*set| {
                var it = set.elements.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit();
                }
                set.elements.deinit();
            },
        }
    }

    /// Applies a mutation to the cell. Returns true if the state was changed.
    pub fn applyUpdateOptimized(self: *Cell, allocator: std.mem.Allocator, op: u8, val: []const u8, meta: LwwMetadata) !bool {
        switch (self.*) {
            .lww_register => |*reg| {
                // Op 0x01 is SET
                if (op == 0x01) {
                    if (meta.supersedes(reg.metadata)) {
                        allocator.free(reg.value);
                        reg.value = try allocator.dupe(u8, val);
                        reg.metadata = meta;
                        return true;
                    }
                }
            },
            .pn_counter => |*cnt| {
                // Op 0x02 is ADD/INC
                if (op == 0x02) {
                    const delta = std.mem.readInt(i64, val[0..8], .little);
                    const last_ts = cnt.timestamps.get(meta.node_id) orelse 0;
                    if (meta.timestamp > 0 and meta.timestamp <= last_ts) {
                        return false; // Already applied this or a newer update
                    }

                    const entry = try cnt.counts.getOrPut(meta.node_id);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = 0;
                    }
                    entry.value_ptr.* += delta;
                    try cnt.timestamps.put(meta.node_id, meta.timestamp);
                    return true;
                }
            },
            .aw_set => |*set| {
                // Op 0x03 is ADD, Op 0x04 is REMOVE
                if (op == 0x03) {
                    var entry = try set.elements.getOrPut(val);
                    if (!entry.found_existing) {
                        entry.key_ptr.* = try allocator.dupe(u8, val);
                        entry.value_ptr.* = std.ArrayList(LwwMetadata).init(allocator);
                    } else {
                        // Check for duplicate dot
                        for (entry.value_ptr.items) |dot| {
                            if (dot.timestamp == meta.timestamp and dot.node_id == meta.node_id) {
                                return false; // Duplicate ADD dot
                            }
                        }
                    }
                    try entry.value_ptr.append(meta);
                    return true;
                } else if (op == 0x04) {
                    if (set.elements.fetchRemove(val)) |entry| {
                        allocator.free(entry.key);
                        entry.value.deinit();
                        return true;
                    }
                }
            },
        }
        return false;
    }

    /// Returns a human-readable representation of the cell value.
    pub fn getValueString(self: Cell, allocator: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .lww_register => |reg| return try allocator.dupe(u8, reg.value),
            .pn_counter => |cnt| {
                var total: i64 = 0;
                var it = cnt.counts.valueIterator();
                while (it.next()) |v| total += v.*;
                return std.fmt.allocPrint(allocator, "{}", .{total});
            },
            .aw_set => |set| {
                var list = std.ArrayList(u8).init(allocator);
                try list.appendSlice("[");
                var it = set.elements.keyIterator();
                var first = true;
                while (it.next()) |k| {
                    if (!first) try list.appendSlice(", ");
                    try list.appendSlice(k.*);
                    first = false;
                }
                try list.appendSlice("]");
                return list.toOwnedSlice();
            },
        }
    }
};

pub const Row = struct {
    pk: []u8,
    cells: std.ArrayList(Cell),
    expires_at: ?i64 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.pk);
        for (self.cells.items) |*cell| {
            cell.deinit(allocator);
        }
        self.cells.deinit();
    }
};

pub const Table = struct {
    name: []const u8,
    rows: std.StringHashMap(*Row), // PK -> Row mapping
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Table {
        return .{
            .name = name,
            .rows = std.StringHashMap(*Row).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        var it = self.rows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.rows.deinit();
    }

    pub fn getOrCreateRow(self: *Table, pk: []const u8) !*Row {
        if (self.rows.get(pk)) |row| return row;

        const row = try self.allocator.create(Row);
        errdefer self.allocator.destroy(row);

        row.* = .{
            .pk = try self.allocator.dupe(u8, pk),
            .cells = std.ArrayList(Cell).init(self.allocator),
        };

        try self.rows.put(row.pk, row);
        return row;
    }
};

test "LWW Register CRDT" {
    const allocator = std.testing.allocator;
    var reg_cell = Cell{
        .lww_register = .{
            .value = try allocator.dupe(u8, "initial"),
            .metadata = .{ .timestamp = 10, .node_id = 1 },
        },
    };
    defer reg_cell.deinit(allocator);

    // Write with higher timestamp: should update
    const updated1 = try reg_cell.applyUpdateOptimized(allocator, 0x01, "new_val", .{ .timestamp = 20, .node_id = 1 });
    try std.testing.expect(updated1);
    try std.testing.expectEqualStrings("new_val", reg_cell.lww_register.value);

    // Write with lower timestamp: should not update
    const updated2 = try reg_cell.applyUpdateOptimized(allocator, 0x01, "ignored", .{ .timestamp = 15, .node_id = 1 });
    try std.testing.expect(!updated2);
    try std.testing.expectEqualStrings("new_val", reg_cell.lww_register.value);

    // Write with equal timestamp but higher node_id: should update
    const updated3 = try reg_cell.applyUpdateOptimized(allocator, 0x01, "tie_breaker", .{ .timestamp = 20, .node_id = 2 });
    try std.testing.expect(updated3);
    try std.testing.expectEqualStrings("tie_breaker", reg_cell.lww_register.value);

    // Write with equal timestamp but lower node_id: should not update
    const updated4 = try reg_cell.applyUpdateOptimized(allocator, 0x01, "ignored_tie", .{ .timestamp = 20, .node_id = 1 });
    try std.testing.expect(!updated4);
    try std.testing.expectEqualStrings("tie_breaker", reg_cell.lww_register.value);
}

test "PN Counter CRDT" {
    const allocator = std.testing.allocator;
    var pn_cell = Cell{
        .pn_counter = .{
            .counts = std.AutoHashMap(u32, i64).init(allocator),
            .timestamps = std.AutoHashMap(u32, i64).init(allocator),
        },
    };
    defer pn_cell.deinit(allocator);

    // Apply +5 from Node 1 at t=10
    var buf_inc: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf_inc, 5, .little);
    const updated1 = try pn_cell.applyUpdateOptimized(allocator, 0x02, &buf_inc, .{ .timestamp = 10, .node_id = 1 });
    try std.testing.expect(updated1);

    // Apply +10 from Node 2 at t=15
    std.mem.writeInt(i64, &buf_inc, 10, .little);
    const updated2 = try pn_cell.applyUpdateOptimized(allocator, 0x02, &buf_inc, .{ .timestamp = 15, .node_id = 2 });
    try std.testing.expect(updated2);

    // Try applying a duplicate/older update: +20 from Node 1 at t=9 (should be ignored)
    std.mem.writeInt(i64, &buf_inc, 20, .little);
    const updated_dup = try pn_cell.applyUpdateOptimized(allocator, 0x02, &buf_inc, .{ .timestamp = 9, .node_id = 1 });
    try std.testing.expect(!updated_dup);

    // Try applying a duplicate update: +20 from Node 1 at t=10 (should be ignored)
    const updated_dup2 = try pn_cell.applyUpdateOptimized(allocator, 0x02, &buf_inc, .{ .timestamp = 10, .node_id = 1 });
    try std.testing.expect(!updated_dup2);

    // Apply -3 from Node 1 at t=20 (using Node 1 again, newer timestamp)
    std.mem.writeInt(i64, &buf_inc, -3, .little);
    const updated3 = try pn_cell.applyUpdateOptimized(allocator, 0x02, &buf_inc, .{ .timestamp = 20, .node_id = 1 });
    try std.testing.expect(updated3);

    // Verify value representation: 5 + 10 - 3 = 12
    const val_str = try pn_cell.getValueString(allocator);
    defer allocator.free(val_str);
    try std.testing.expectEqualStrings("12", val_str);
}

test "AW Set CRDT" {
    const allocator = std.testing.allocator;
    var aw_cell = Cell{
        .aw_set = .{
            .elements = std.StringHashMap(std.ArrayList(LwwMetadata)).init(allocator),
        },
    };
    defer aw_cell.deinit(allocator);

    // Add "apple" from Node 1 at t=10
    const updated1 = try aw_cell.applyUpdateOptimized(allocator, 0x03, "apple", .{ .timestamp = 10, .node_id = 1 });
    try std.testing.expect(updated1);

    // Add "banana" from Node 2 at t=15
    const updated2 = try aw_cell.applyUpdateOptimized(allocator, 0x03, "banana", .{ .timestamp = 15, .node_id = 2 });
    try std.testing.expect(updated2);

    // Verify both are present in the value string
    const val_str1 = try aw_cell.getValueString(allocator);
    defer allocator.free(val_str1);
    try std.testing.expect(std.mem.indexOf(u8, val_str1, "apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, val_str1, "banana") != null);

    // Remove "apple"
    const updated3 = try aw_cell.applyUpdateOptimized(allocator, 0x04, "apple", .{ .timestamp = 20, .node_id = 1 });
    try std.testing.expect(updated3);

    const val_str2 = try aw_cell.getValueString(allocator);
    defer allocator.free(val_str2);
    try std.testing.expect(std.mem.indexOf(u8, val_str2, "apple") == null);
    try std.testing.expect(std.mem.indexOf(u8, val_str2, "banana") != null);
}

