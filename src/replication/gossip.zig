const std = @import("std");
const db_mod = @import("../db.zig");
const protocol = @import("../protocol/frame.zig");

pub const GossipManager = struct {
    db: *db_mod.Database,
    allocator: std.mem.Allocator,
    my_port: u16,

    pub fn init(allocator: std.mem.Allocator, db: *db_mod.Database, my_port: u16) GossipManager {
        return .{
            .db = db,
            .allocator = allocator,
            .my_port = my_port,
        };
    }

    pub fn start(self: *GossipManager) !std.Thread {
        return try std.Thread.spawn(.{}, runGossipLoop, .{self});
    }

    fn runGossipLoop(self: *GossipManager) void {
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.real, self.db.io).toMilliseconds()));
        const random = prng.random();

        while (true) {
            std.Io.sleep(self.db.io, std.Io.Duration.fromSeconds(2), .awake) catch {};

            // 1. Check for dead peers
            self.checkHealth();

            // 2. Pick a random peer to gossip with
            const target = blk: {
                self.db.peers_mutex.lockUncancelable(self.db.io);
                defer self.db.peers_mutex.unlock(self.db.io);
                const peers_count = self.db.peers.count();
                if (peers_count == 0) break :blk null;

                var it = self.db.peers.valueIterator();
                const target_idx = random.uintLessThan(usize, peers_count);
                var i: usize = 0;
                while (i < target_idx) : (i += 1) _ = it.next();
                break :blk it.next().?.*;
            };

            if (target) |t| {
                self.gossipWith(t) catch |err| {
                    // If we can't talk to a peer, it will eventually be reaped by checkHealth
                    std.debug.print("Gossip failed with {}: {}\n", .{t.address, err});
                };
            }
        }
    }

    fn checkHealth(self: *GossipManager) void {
        const now = std.Io.Clock.now(.real, self.db.io).toMilliseconds();
        const timeout = 10 * 1000; // 10 seconds of inactivity = dead

        var to_remove = std.array_list.Managed(u32).init(self.allocator);
        defer to_remove.deinit();

        {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            var it = self.db.peers.iterator();
            while (it.next()) |entry| {
                const peer = entry.value_ptr.*;
                if (now - peer.last_seen > timeout) {
                    to_remove.append(entry.key_ptr.*) catch {};
                }
            }
        }

        if (to_remove.items.len > 0) {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            for (to_remove.items) |id| {
                if (self.db.peers.get(id)) |peer| {
                    std.debug.print("Node {} (addr={}) timed out. Removing from cluster.\n", .{ peer.id, peer.address });
                    _ = self.db.peers.remove(id);
                }
            }
        }
    }

    fn gossipWith(self: *GossipManager, target: db_mod.Peer) !void {
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        // 1. Include myself in the gossip list
        try writer.writeInt(u32, self.db.node_id, .little);
        try writer.writeInt(u16, self.my_port, .little);

        // 2. Include other known peers (limit to 5 to keep packet small)
        {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            var it = self.db.peers.valueIterator();
            var count: usize = 0;
            while (it.next()) |peer| {
                if (count >= 5) break;
                if (peer.id == target.id) continue;
                try writer.writeInt(u32, peer.id, .little);
                // This is a simplification: we assume peers are on 127.0.0.1 for this demo
                // In real use, we'd send the full IP.
                const port = peer.address.getPort();
                try writer.writeInt(u16, port, .little);
                count += 1;
            }
        }

        const written_payload = aw.written();
        const header = protocol.Header{
            .msg_type = .gossip,
            .stream_id = 0,
            .payload_len = @intCast(written_payload.len),
            .sequence = 0,
        };

        const stream = std.Io.net.IpAddress.connect(&target.address, self.db.io, .{ .mode = .stream }) catch |err| {
            std.debug.print("Node {} gossip: connect to {} failed: {}\n", .{self.db.node_id, target.address, err});
            return;
        };
        defer stream.close(self.db.io);

        var write_buf: [1024]u8 = undefined;
        var conn_writer = stream.writer(self.db.io, &write_buf);
        const conn_w = &conn_writer.interface;
        try conn_w.writeAll(std.mem.asBytes(&header));
        try conn_w.writeAll(written_payload);
        try conn_w.flush();
        std.debug.print("Node {} sent gossip to node {} ({})\n", .{self.db.node_id, target.id, target.address});
    }

    pub fn handleGossip(self: *GossipManager, payload: []const u8) !void {
        var reader = std.Io.Reader.fixed(payload);

        while (reader.seek < reader.end) {
            const id = try reader.takeInt(u32, .little);
            const port = try reader.takeInt(u16, .little);
            
            if (id != self.db.node_id) {
                const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
                std.debug.print("Node {} received gossip: peer {} at port {}\n", .{self.db.node_id, id, port});
                try self.db.addOrUpdatePeer(id, addr);
            }
        }
    }
};
