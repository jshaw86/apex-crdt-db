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
            std.Io.sleep(self.db.io, std.Io.Duration.fromSeconds(5), .awake) catch {};

            const peers_count = blk: {
                self.db.peers_mutex.lockUncancelable(self.db.io);
                defer self.db.peers_mutex.unlock(self.db.io);
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
        
        const now = std.Io.Clock.now(.real, self.db.io).toMilliseconds();
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

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

        const written_payload = aw.written();
        const header = protocol.Header{
            .msg_type = .sync,
            .stream_id = 0,
            .payload_len = @intCast(written_payload.len),
            .sequence = 0,
        };

        var target_peers = std.array_list.Managed(db_mod.Peer).init(self.allocator);
        defer target_peers.deinit();
        {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            var it = self.db.peers.valueIterator();
            while (it.next()) |peer| {
                try target_peers.append(peer.*);
            }
        }

        for (target_peers.items) |peer| {
            const stream = std.Io.net.IpAddress.connect(&peer.address, self.db.io, .{ .mode = .stream }) catch continue;
            defer stream.close(self.db.io);
            var write_buf: [1024]u8 = undefined;
            var conn_writer = stream.writer(self.db.io, &write_buf);
            const conn_w = &conn_writer.interface;
            try conn_w.writeAll(std.mem.asBytes(&header));
            try conn_w.writeAll(written_payload);
            try conn_w.flush();
            std.debug.print("Pushed {} deltas to peer {}\n", .{delta_count, peer.address});
        }
    }
};
