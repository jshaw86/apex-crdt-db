const std = @import("std");
const engine = @import("storage/engine.zig");
const schema_mod = @import("schema/engine.zig");

const Mutation = struct {
    table_id: u16,
    pk: []u8,
    col_idx: u8,
    op: u8,
    val: []u8,
    meta: engine.LwwMetadata,
};

pub const Database = struct {
    tables: std.StringHashMap(*engine.Table),
    schema_registry: schema_mod.SchemaRegistry,
    allocator: std.mem.Allocator,
    node_id: u32,
    peers: std.AutoHashMap(u32, Peer),
    peers_mutex: std.Thread.Mutex,
    
    // Version Vector: NodeID -> Highest Sequence seen
    version_vector: std.AutoHashMap(u32, u64),
    // Oplog: A history of mutations for delta sync
    oplog: std.ArrayList(Mutation),
    next_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, node_id: u32) Database {
        return .{
            .tables = std.StringHashMap(*engine.Table).init(allocator),
            .schema_registry = schema_mod.SchemaRegistry.init(allocator),
            .allocator = allocator,
            .node_id = node_id,
            .peers = std.AutoHashMap(u32, Peer).init(allocator),
            .peers_mutex = .{},
            .version_vector = std.AutoHashMap(u32, u64).init(allocator),
            .oplog = std.ArrayList(Mutation).init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tables.deinit();
        self.schema_registry.deinit();
        self.peers.deinit();
        self.version_vector.deinit();
        for (self.oplog.items) |m| {
            self.allocator.free(m.pk);
            self.allocator.free(m.val);
        }
        self.oplog.deinit();
    }

    pub fn addOrUpdatePeer(self: *Database, id: u32, address: std.net.Address) !void {
        if (id == self.node_id) return;
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        // Check if there is an existing entry for this port with a different ID (e.g. placeholder ID 0)
        var it = self.peers.iterator();
        var old_id_to_remove: ?u32 = null;
        const port = address.getPort();
        while (it.next()) |entry| {
            if (entry.value_ptr.id != id and entry.value_ptr.address.getPort() == port) {
                old_id_to_remove = entry.key_ptr.*;
                break;
            }
        }
        if (old_id_to_remove) |old_id| {
            _ = self.peers.remove(old_id);
        }

        try self.peers.put(id, .{
            .id = id,
            .address = address,
            .last_seen = std.time.milliTimestamp(),
        });
    }

    pub fn registerSchema(self: *Database, schema: *schema_mod.TableSchema) !void {
        try self.schema_registry.register(schema);
        
        const table = try self.allocator.create(engine.Table);
        table.* = engine.Table.init(self.allocator, schema.name);
        try self.tables.put(schema.name, table);
        
        std.debug.print("Registered Table: {s} (ID: {})\n", .{ schema.name, schema.id });
    }

    /// Process a binary mutation payload.
    /// Format: [TableID: u16][TTL: u32][PK_Len: u16][PK: Bytes][MutationCount: u8]
    pub fn processMutation(self: *Database, payload: []const u8, is_sync: bool) !void {
        var fbs = std.io.fixedBufferStream(payload);
        const reader = fbs.reader();

        while (fbs.pos < payload.len) {
            const table_id = reader.readInt(u16, .little) catch break;
            const ttl_seconds: u32 = 0;
            
            const schema = self.schema_registry.getById(table_id) orelse {
                std.debug.print("Mutation Error: Table ID {} not found in registry\n", .{table_id});
                return error.TableNotFound;
            };
            const table = self.tables.get(schema.name) orelse return error.TableNotFound;

            const pk_len = try reader.readInt(u16, .little);
            const pk = payload[fbs.pos .. fbs.pos + pk_len];
            try fbs.seekBy(@intCast(pk_len));

            const row = try table.getOrCreateRow(pk);
            
            // Set TTL if provided
            if (ttl_seconds > 0) {
                row.expires_at = std.time.milliTimestamp() + (@as(i64, ttl_seconds) * 1000);
            }

            const mutation_count = try reader.readByte();
            var i: u8 = 0;
            while (i < mutation_count) : (i += 1) {
                const col_idx = try reader.readByte();
                const op = try reader.readByte();

                if (col_idx >= schema.columns.items.len) return error.ColumnOutOfRange;
                const col_def = schema.columns.items[col_idx];

                var meta: engine.LwwMetadata = undefined;
                if (is_sync) {
                    meta.timestamp = try reader.readInt(i64, .little);
                    meta.node_id = try reader.readInt(u32, .little);
                } else {
                    meta = .{
                        .timestamp = std.time.milliTimestamp(),
                        .node_id = self.node_id,
                    };
                }

                const val_len = try reader.readInt(u16, .little);
                const val = payload[fbs.pos .. fbs.pos + val_len];
                try fbs.seekBy(@intCast(val_len));

                // CRDT Merge
                const cell = try self.ensureCell(row, col_idx, col_def.crdt_type);
                
                // Enforce type during apply
                if (std.meta.activeTag(cell.*) != col_def.crdt_type) return error.TypeMismatch;

                const was_applied = try cell.applyUpdateOptimized(self.allocator, op, val, meta);

                if (was_applied) {
                    try self.oplog.append(.{
                        .table_id = table_id,
                        .pk = try self.allocator.dupe(u8, pk),
                        .col_idx = col_idx,
                        .op = op,
                        .val = try self.allocator.dupe(u8, val),
                        .meta = meta,
                    });
                }
            }
        }
    }

    fn ensureCell(self: *Database, row: *engine.Row, col_idx: u8, crdt_type: engine.CrdtType) !*engine.Cell {
        while (row.cells.items.len <= col_idx) {
            const cell: engine.Cell = switch (crdt_type) {
                .lww_register => .{
                    .lww_register = .{
                        .value = try self.allocator.dupe(u8, ""),
                        .metadata = .{ .timestamp = 0, .node_id = 0 },
                    },
                },
                .pn_counter => .{
                    .pn_counter = .{
                        .counts = std.AutoHashMap(u32, i64).init(self.allocator),
                        .timestamps = std.AutoHashMap(u32, i64).init(self.allocator),
                    },
                },
                .aw_set => .{
                    .aw_set = .{
                        .elements = std.StringHashMap(std.ArrayList(engine.LwwMetadata)).init(self.allocator),
                    },
                },
            };
            try row.cells.append(cell);
        }
        return &row.cells.items[col_idx];
    }

    /// Processes a query payload and returns a serialized response.
    /// Request Format: [TableID: u16][PK_Len: u16][PK: Bytes]
    ///   If PK_Len is 0, performs a full TABLE SCAN.
    pub fn processQuery(self: *Database, payload: []const u8, out_buffer: *std.ArrayList(u8)) !void {
        var fbs = std.io.fixedBufferStream(payload);
        const reader = fbs.reader();
        const writer = out_buffer.writer();

        const table_id = try reader.readInt(u16, .little);
        const schema = self.schema_registry.getById(table_id) orelse {
            try writer.writeByte(0x01); // Status: Not Found
            return;
        };
        const table = self.tables.get(schema.name) orelse return error.TableNotFound;

        const pk_len = try reader.readInt(u16, .little);
        
        if (pk_len == 0) {
            // --- TABLE SCAN (SELECT *) ---
            try writer.writeByte(0x00); // Status: OK
            try writer.writeInt(u32, @intCast(table.rows.count()), .little); // Row count

            var row_it = table.rows.valueIterator();
            while (row_it.next()) |row_ptr| {
                const row = row_ptr.*;
                try writer.writeInt(u16, @intCast(row.pk.len), .little);
                try writer.writeAll(row.pk);
                try writer.writeByte(@intCast(row.cells.items.len));
                for (row.cells.items) |cell| {
                    try writer.writeByte(@intFromEnum(std.meta.activeTag(cell)));
                    const val = try cell.getValueString(self.allocator);
                    defer self.allocator.free(val);
                    try writer.writeInt(u16, @intCast(val.len), .little);
                    try writer.writeAll(val);
                }
            }
        } else {
            // --- POINT LOOKUP ---
            const pk = payload[fbs.pos .. fbs.pos + pk_len];
            if (table.rows.get(pk)) |row| {
                try writer.writeByte(0x00); // Status: OK
                try writer.writeInt(u32, 1, .little); // Returning 1 row
                try writer.writeInt(u16, @intCast(row.pk.len), .little);
                try writer.writeAll(row.pk);
                try writer.writeByte(@intCast(row.cells.items.len));
                for (row.cells.items) |cell| {
                    try writer.writeByte(@intFromEnum(std.meta.activeTag(cell)));
                    const val = try cell.getValueString(self.allocator);
                    defer self.allocator.free(val);
                    try writer.writeInt(u16, @intCast(val.len), .little);
                    try writer.writeAll(val);
                }
            } else {
                try writer.writeByte(0x01); // Status: Not Found
            }
        }
    }

    pub fn serializeSync(self: *Database, table_name: []const u8, out_buffer: *std.ArrayList(u8)) !void {
        const table = self.tables.get(table_name) orelse return error.TableNotFound;
        const schema = self.schema_registry.getByName(table_name) orelse return error.SchemaNotFound;
        const writer = out_buffer.writer();

        try writer.writeInt(u16, schema.id, .little);

        var row_it = table.rows.iterator();
        while (row_it.next()) |row_entry| {
            const row = row_entry.value_ptr.*;
            try writer.writeInt(u16, @intCast(row.pk.len), .little);
            try writer.writeAll(row.pk);

            try writer.writeByte(@intCast(row.cells.items.len));
            for (row.cells.items, 0..) |cell, col_idx| {
                try writer.writeByte(@intCast(col_idx));
                
                switch (cell) {
                    .lww_register => |reg| {
                        try writer.writeByte(1); // Op SET
                        try writer.writeInt(i64, reg.metadata.timestamp, .little);
                        try writer.writeInt(u32, reg.metadata.node_id, .little);
                        try writer.writeInt(u16, @intCast(reg.value.len), .little);
                        try writer.writeAll(reg.value);
                    },
                    .pn_counter => |cnt| {
                        var c_it = cnt.counts.iterator();
                        while (c_it.next()) |c_entry| {
                            try writer.writeByte(2); // Op ADD
                            try writer.writeInt(i64, 0, .little); // Dummy timestamp
                            try writer.writeInt(u32, c_entry.key_ptr.*, .little);
                            try writer.writeInt(u16, 8, .little);
                            try writer.writeInt(i64, c_entry.value_ptr.*, .little);
                        }
                    },
                    .aw_set => |set| {
                        var s_it = set.elements.iterator();
                        while (s_it.next()) |s_entry| {
                            for (s_entry.value_ptr.items) |dot| {
                                try writer.writeByte(3); // Op ADD
                                try writer.writeInt(i64, dot.timestamp, .little);
                                try writer.writeInt(u32, dot.node_id, .little);
                                try writer.writeInt(u16, @intCast(s_entry.key_ptr.*.len), .little);
                                try writer.writeAll(s_entry.key_ptr.*);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
};

pub const Peer = struct {
    id: u32,
    address: std.net.Address,
    last_seen: i64,
};
