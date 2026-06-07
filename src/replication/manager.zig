const std = @import("std");
const db_mod = @import("../db.zig");
const protocol = @import("../protocol/frame.zig");

pub const ReplicationManager = struct {
    db: *db_mod.Database,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: *db_mod.Database) ReplicationManager {
        return .{
            .db = db,
            .allocator = allocator,
        };
    }

    /// Spawns a background thread that periodically sends state to peers.
    pub fn start(self: *ReplicationManager) !std.Thread {
        return try std.Thread.spawn(.{}, runSyncLoop, .{self});
    }

    fn runSyncLoop(self: *ReplicationManager) void {
        while (true) {
            std.time.sleep(5 * std.time.ns_per_s); // Sync every 5 seconds

            const peers_count = blk: {
                self.db.peers_mutex.lock();
                defer self.db.peers_mutex.unlock();
                break :blk self.db.peers.count();
            };
            if (peers_count == 0) continue;

            self.syncToPeers() catch |err| {
                std.debug.print("Sync error: {}\n", .{err});
            };
        }
    }

    fn syncToPeers(self: *ReplicationManager) !void {
        // In a real delta sync, we'd:
        // 1. Send our Version Vector to the peer.
        // 2. Peer replies with missing mutations from their oplog.
        // 3. We apply them.
        
        // For now, we'll implement "Push Delta": Send all mutations from our oplog
        // that have a timestamp newer than 5 seconds ago.
        
        const now = std.time.milliTimestamp();
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        const writer = payload.writer();

        var delta_count: u32 = 0;
        for (self.db.oplog.items) |m| {
            if (now - m.meta.timestamp < 5000) {
                try writer.writeInt(u16, m.table_id, .little);
                try writer.writeInt(u16, @intCast(m.pk.len), .little);
                try writer.writeAll(m.pk);
                try writer.writeByte(1); // One mutation per "mini-frame" in this delta
                try writer.writeByte(m.col_idx);
                try writer.writeByte(m.op);
                try writer.writeInt(i64, m.meta.timestamp, .little);
                try writer.writeInt(u32, m.meta.node_id, .little);
                try writer.writeInt(u16, @intCast(m.val.len), .little);
                try writer.writeAll(m.val);
                delta_count += 1;
            }
        }

        if (delta_count == 0) return;

        const header = protocol.Header{
            .msg_type = .sync,
            .stream_id = 0,
            .payload_len = @intCast(payload.items.len),
            .sequence = 0,
        };

        var target_peers = std.ArrayList(db_mod.Peer).init(self.allocator);
        defer target_peers.deinit();
        {
            self.db.peers_mutex.lock();
            defer self.db.peers_mutex.unlock();
            var it = self.db.peers.valueIterator();
            while (it.next()) |peer| {
                try target_peers.append(peer.*);
            }
        }

        for (target_peers.items) |peer| {
            const stream = std.net.tcpConnectToAddress(peer.address) catch continue;
            defer stream.close();
            try stream.writer().writeAll(std.mem.asBytes(&header));
            try stream.writer().writeAll(payload.items);
            std.debug.print("Pushed {} deltas to peer {}\n", .{delta_count, peer.address});
        }
    }
};
