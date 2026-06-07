const std = @import("std");
const engine = @import("../storage/engine.zig");

pub const ColumnDefinition = struct {
    name: []const u8,
    crdt_type: engine.CrdtType,

    pub fn deinit(self: *ColumnDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const TableSchema = struct {
    id: u16,
    name: []const u8,
    columns: std.ArrayList(ColumnDefinition),

    pub fn init(allocator: std.mem.Allocator, id: u16, name: []const u8) TableSchema {
        return .{
            .id = id,
            .name = name,
            .columns = std.ArrayList(ColumnDefinition).init(allocator),
        };
    }

    pub fn deinit(self: *TableSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.columns.items) |*col| {
            col.deinit(allocator);
        }
        self.columns.deinit();
    }

    pub fn addColumn(self: *TableSchema, allocator: std.mem.Allocator, name: []const u8, crdt_type: engine.CrdtType) !void {
        try self.columns.append(.{
            .name = try allocator.dupe(u8, name),
            .crdt_type = crdt_type,
        });
    }
};

pub const SchemaRegistry = struct {
    schemas_by_id: std.AutoHashMap(u16, *TableSchema),
    schemas_by_name: std.StringHashMap(*TableSchema),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .schemas_by_id = std.AutoHashMap(u16, *TableSchema).init(allocator),
            .schemas_by_name = std.StringHashMap(*TableSchema).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        var it = self.schemas_by_id.valueIterator();
        while (it.next()) |schema| {
            schema.*.deinit(self.allocator);
            self.allocator.destroy(schema.*);
        }
        self.schemas_by_id.deinit();
        self.schemas_by_name.deinit();
    }

    pub fn register(self: *SchemaRegistry, schema: *TableSchema) !void {
        try self.schemas_by_id.put(schema.id, schema);
        try self.schemas_by_name.put(schema.name, schema);
    }

    pub fn getById(self: SchemaRegistry, id: u16) ?*TableSchema {
        return self.schemas_by_id.get(id);
    }

    pub fn getByName(self: SchemaRegistry, name: []const u8) ?*TableSchema {
        return self.schemas_by_name.get(name);
    }
};
