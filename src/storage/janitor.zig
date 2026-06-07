const std = @import("std");
const db_mod = @import("../db.zig");

pub const Janitor = struct {
    db: *db_mod.Database,

    pub fn init(db: *db_mod.Database) Janitor {
        return .{ .db = db };
    }

    pub fn start(self: *Janitor) !std.Thread {
        return try std.Thread.spawn(.{}, runJanitorLoop, .{self});
    }

    fn runJanitorLoop(self: *Janitor) void {
        while (true) {
            std.Io.sleep(self.db.io, std.Io.Duration.fromSeconds(10), .awake) catch {};
            self.sweep() catch |err| {
                std.debug.print("Janitor sweep error: {}\n", .{err});
            };
        }
    }

    fn sweep(self: *Janitor) !void {
        const now = std.Io.Clock.now(.real, self.db.io).toMilliseconds();
        var table_it = self.db.tables.valueIterator();
        
        while (table_it.next()) |table_ptr| {
            const table = table_ptr.*;
            var row_it = table.rows.iterator();
            
            while (row_it.next()) |entry| {
                const row = entry.value_ptr.*;
                if (row.expires_at) |expiry| {
                    if (now > expiry) {
                        std.debug.print("Janitor: Reaping expired row '{s}' in table '{s}'\n", .{ row.pk, table.name });
                        // Delete row
                        row.deinit(self.db.allocator);
                        self.db.allocator.destroy(row);
                        _ = table.rows.remove(entry.key_ptr.*);
                    }
                }
            }
        }
    }
};
