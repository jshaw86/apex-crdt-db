const std = @import("std");
const db_mod = @import("../db.zig");
const protocol = @import("../protocol/frame.zig");

pub const Role = enum {
    leader,
    follower,
    candidate,
};

pub const LogEntry = struct {
    term: u64,
    payload: []u8,
};

pub const Raft = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.Database,
    role: Role = .follower,
    current_term: u64 = 0,
    voted_for: ?u32 = null,
    log: std.array_list.Managed(LogEntry),
    commit_index: usize = 0,
    last_applied: usize = 0,

    leader_id: ?u32 = null,
    last_heartbeat_time: i64 = 0,
    last_heartbeat_send_time: i64 = 0,
    election_timeout_ms: i64 = 300,

    mutex: std.Io.Mutex = .init,
    prng: std.Random.DefaultPrng,

    // Leader tracking
    next_index: std.AutoHashMap(u32, usize),
    match_index: std.AutoHashMap(u32, usize),

    // Active election votes
    votes: std.AutoHashMap(u32, bool),

    pub fn init(allocator: std.mem.Allocator, db: *db_mod.Database) Raft {
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.real, db.io).toMilliseconds() + db.node_id));
        const timeout = prng.random().intRangeAtMost(i64, 250, 450);
        return .{
            .allocator = allocator,
            .db = db,
            .log = std.array_list.Managed(LogEntry).init(allocator),
            .prng = prng,
            .election_timeout_ms = timeout,
            .next_index = std.AutoHashMap(u32, usize).init(allocator),
            .match_index = std.AutoHashMap(u32, usize).init(allocator),
            .votes = std.AutoHashMap(u32, bool).init(allocator),
            .last_heartbeat_time = std.Io.Clock.now(.real, db.io).toMilliseconds(),
        };
    }

    pub fn deinit(self: *Raft) void {
        for (self.log.items) |entry| {
            self.allocator.free(entry.payload);
        }
        self.log.deinit();
        self.next_index.deinit();
        self.match_index.deinit();
        self.votes.deinit();
    }

    pub fn start(self: *Raft) !std.Thread {
        return try std.Thread.spawn(.{}, runRaftLoop, .{self});
    }

    fn runRaftLoop(self: *Raft) void {
        while (true) {
            std.Io.sleep(self.db.io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};

            const now = std.Io.Clock.now(.real, self.db.io).toMilliseconds();
            var should_elect = false;
            var should_heartbeat = false;

            {
                self.mutex.lockUncancelable(self.db.io);
                defer self.mutex.unlock(self.db.io);

                if (self.role == .leader) {
                    if (now - self.last_heartbeat_send_time > 100) {
                        should_heartbeat = true;
                        self.last_heartbeat_send_time = now;
                    }
                } else {
                    if (now - self.last_heartbeat_time > self.election_timeout_ms) {
                        should_elect = true;
                        self.last_heartbeat_time = now;
                        // Randomize next timeout to prevent split votes
                        self.election_timeout_ms = self.prng.random().intRangeAtMost(i64, 250, 450);
                    }
                }
            }

            if (should_elect) {
                self.startElection() catch |err| {
                    std.debug.print("Election error: {}\n", .{err});
                };
            }

            if (should_heartbeat) {
                self.sendHeartbeats() catch |err| {
                    std.debug.print("Heartbeat error: {}\n", .{err});
                };
            }
        }
    }

    fn startElection(self: *Raft) !void {
        self.mutex.lockUncancelable(self.db.io);
        self.role = .candidate;
        self.current_term += 1;
        self.voted_for = self.db.node_id;
        self.votes.clearRetainingCapacity();
        try self.votes.put(self.db.node_id, true); // Vote for self

        const term = self.current_term;
        const last_index: u64 = self.log.items.len;
        const last_term: u64 = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].term else 0;

        // Check if we immediately won (majority in 1-node cluster)
        const total_nodes = self.db.peers.count() + 1;
        const majority = (total_nodes / 2) + 1;
        if (self.votes.count() >= majority) {
            self.role = .leader;
            self.leader_id = self.db.node_id;
            std.debug.print("Node {} elected leader for term {} (immediately/solo)\n", .{self.db.node_id, term});
            
            self.next_index.clearRetainingCapacity();
            self.match_index.clearRetainingCapacity();
            var it = self.db.peers.valueIterator();
            while (it.next()) |peer| {
                try self.next_index.put(peer.id, self.log.items.len + 1);
                try self.match_index.put(peer.id, 0);
            }
        }
        self.mutex.unlock(self.db.io);

        if (self.role == .leader) return;

        std.debug.print("Node {} starting election for term {}\n", .{self.db.node_id, term});

        // Broadcast RequestVote
        var payload_buf: [28]u8 = undefined;
        std.mem.writeInt(u32, payload_buf[0..4], self.db.node_id, .little);
        std.mem.writeInt(u64, payload_buf[4..12], term, .little);
        std.mem.writeInt(u64, payload_buf[12..20], last_index, .little);
        std.mem.writeInt(u64, payload_buf[20..28], last_term, .little);

        const header = protocol.Header{
            .msg_type = .raft_request_vote,
            .stream_id = 0,
            .payload_len = @intCast(payload_buf.len),
            .sequence = 0,
        };

        var peers_list = std.array_list.Managed(db_mod.Peer).init(self.allocator);
        defer peers_list.deinit();
        {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            var it = self.db.peers.valueIterator();
            while (it.next()) |peer| {
                try peers_list.append(peer.*);
            }
        }

        for (peers_list.items) |peer| {
            const stream = std.Io.net.IpAddress.connect(&peer.address, self.db.io, .{ .mode = .stream }) catch continue;
            defer stream.close(self.db.io);
            var write_buf: [1024]u8 = undefined;
            var conn_writer = stream.writer(self.db.io, &write_buf);
            const writer = &conn_writer.interface;
            try writer.writeAll(std.mem.asBytes(&header));
            try writer.writeAll(&payload_buf);
            try writer.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var conn_reader = stream.reader(self.db.io, &read_buf);
            const reader = &conn_reader.interface;

            var resp_header_buf: [protocol.Header.SIZE]u8 = undefined;
            const bytes_read = reader.readSliceShort(&resp_header_buf) catch continue;
            if (bytes_read < protocol.Header.SIZE) continue;
            const resp_header = std.mem.bytesToValue(protocol.Header, &resp_header_buf);
            if (resp_header.msg_type != .raft_request_vote_resp) continue;

            const resp_payload = self.allocator.alloc(u8, resp_header.payload_len) catch continue;
            defer self.allocator.free(resp_payload);
            reader.readSliceAll(resp_payload) catch continue;

            try self.handleRequestVoteResp(resp_payload);
        }
    }

    fn sendHeartbeats(self: *Raft) !void {
        var peers_list = std.array_list.Managed(db_mod.Peer).init(self.allocator);
        defer peers_list.deinit();
        {
            self.db.peers_mutex.lockUncancelable(self.db.io);
            defer self.db.peers_mutex.unlock(self.db.io);
            var it = self.db.peers.valueIterator();
            while (it.next()) |peer| {
                try peers_list.append(peer.*);
            }
        }

        for (peers_list.items) |peer| {
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            defer aw.deinit();
            const writer = &aw.writer;

            var next_idx: usize = 1;
            var term: u64 = 0;
            var commit_idx: usize = 0;
            var prev_index: usize = 0;
            var prev_term: u64 = 0;
            var entries_count: u32 = 0;

            // Lock briefly to gather state for this peer
            {
                self.mutex.lockUncancelable(self.db.io);
                defer self.mutex.unlock(self.db.io);

                if (self.role != .leader) return;

                next_idx = self.next_index.get(peer.id) orelse 1;
                term = self.current_term;
                commit_idx = self.commit_index;
                prev_index = next_idx - 1;
                prev_term = if (prev_index > 0 and prev_index <= self.log.items.len) self.log.items[prev_index - 1].term else 0;

                const entries_to_send = if (self.log.items.len >= next_idx) self.log.items[next_idx - 1 ..] else &[_]LogEntry{};
                entries_count = @intCast(entries_to_send.len);

                try writer.writeInt(u32, self.db.node_id, .little);
                try writer.writeInt(u64, term, .little);
                try writer.writeInt(u64, prev_index, .little);
                try writer.writeInt(u64, prev_term, .little);
                try writer.writeInt(u64, commit_idx, .little);
                try writer.writeInt(u32, entries_count, .little);

                for (entries_to_send) |entry| {
                    try writer.writeInt(u64, entry.term, .little);
                    try writer.writeInt(u32, @intCast(entry.payload.len), .little);
                    try writer.writeAll(entry.payload);
                }
            }

            const payload = aw.written();
            const header = protocol.Header{
                .msg_type = .raft_append_entries,
                .stream_id = 0,
                .payload_len = @intCast(payload.len),
                .sequence = 0,
            };

            const stream = std.Io.net.IpAddress.connect(&peer.address, self.db.io, .{ .mode = .stream }) catch continue;
            defer stream.close(self.db.io);
            var write_buf: [1024]u8 = undefined;
            var conn_writer = stream.writer(self.db.io, &write_buf);
            const conn_w = &conn_writer.interface;
            try conn_w.writeAll(std.mem.asBytes(&header));
            try conn_w.writeAll(payload);
            try conn_w.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var conn_reader = stream.reader(self.db.io, &read_buf);
            const reader = &conn_reader.interface;

            var resp_header_buf: [protocol.Header.SIZE]u8 = undefined;
            const bytes_read = reader.readSliceShort(&resp_header_buf) catch continue;
            if (bytes_read < protocol.Header.SIZE) continue;
            const resp_header = std.mem.bytesToValue(protocol.Header, &resp_header_buf);
            if (resp_header.msg_type != .raft_append_entries_resp) continue;

            const resp_payload = self.allocator.alloc(u8, resp_header.payload_len) catch continue;
            defer self.allocator.free(resp_payload);
            reader.readSliceAll(resp_payload) catch continue;

            try self.handleAppendEntriesResp(resp_payload);
        }
    }

    pub fn handleRequestVote(self: *Raft, payload: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);

        const candidate_id = std.mem.readInt(u32, payload[0..4], .little);
        const term = std.mem.readInt(u64, payload[4..12], .little);
        const last_index = std.mem.readInt(u64, payload[12..20], .little);
        const last_term = std.mem.readInt(u64, payload[20..28], .little);

        if (term > self.current_term) {
            self.current_term = term;
            self.role = .follower;
            self.voted_for = null;
        }

        var vote_granted: u8 = 0;
        if (term == self.current_term and (self.voted_for == null or self.voted_for == candidate_id)) {
            const my_last_index = self.log.items.len;
            const my_last_term = if (self.log.items.len > 0) self.log.items[self.log.items.len - 1].term else 0;

            const log_ok = (last_term > my_last_term) or (last_term == my_last_term and last_index >= my_last_index);
            if (log_ok) {
                self.voted_for = candidate_id;
                vote_granted = 1;
                self.last_heartbeat_time = std.Io.Clock.now(.real, self.db.io).toMilliseconds();
            }
        }

        var resp_buf = try self.allocator.alloc(u8, 13);
        std.mem.writeInt(u32, resp_buf[0..4], self.db.node_id, .little);
        std.mem.writeInt(u64, resp_buf[4..12], self.current_term, .little);
        resp_buf[12] = vote_granted;
        return resp_buf;
    }

    pub fn handleRequestVoteResp(self: *Raft, payload: []const u8) !void {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);

        const voter_id = std.mem.readInt(u32, payload[0..4], .little);
        const term = std.mem.readInt(u64, payload[4..12], .little);
        const vote_granted = payload[12];

        if (term > self.current_term) {
            self.current_term = term;
            self.role = .follower;
            self.voted_for = null;
            return;
        }

        if (self.role == .candidate and term == self.current_term and vote_granted == 1) {
            try self.votes.put(voter_id, true);

            const total_nodes = self.db.peers.count() + 1;
            const majority = (total_nodes / 2) + 1;
            if (self.votes.count() >= majority) {
                self.role = .leader;
                self.leader_id = self.db.node_id;
                std.debug.print("Node {} elected leader for term {}\n", .{self.db.node_id, self.current_term});

                // Initialize next_index and match_index for peers
                var it = self.db.peers.valueIterator();
                while (it.next()) |peer| {
                    try self.next_index.put(peer.id, self.log.items.len + 1);
                    try self.match_index.put(peer.id, 0);
                }
            }
        }
    }

    pub fn handleAppendEntries(self: *Raft, payload: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);

        var reader = std.Io.Reader.fixed(payload);
        const leader_id = try reader.takeInt(u32, .little);
        const term = try reader.takeInt(u64, .little);
        const prev_index = try reader.takeInt(u64, .little);
        const prev_term = try reader.takeInt(u64, .little);
        const leader_commit = try reader.takeInt(u64, .little);
        const entries_count = try reader.takeInt(u32, .little);

        if (term > self.current_term) {
            self.current_term = term;
            self.role = .follower;
            self.voted_for = null;
        }

        var success: u8 = 0;
        if (term == self.current_term) {
            self.role = .follower;
            self.leader_id = leader_id;
            self.last_heartbeat_time = std.Io.Clock.now(.real, self.db.io).toMilliseconds();

            // Validate log consistency
            const log_ok = (prev_index == 0) or 
                           (prev_index <= self.log.items.len and self.log.items[prev_index - 1].term == prev_term);

            if (log_ok) {
                success = 1;

                // Append new entries
                var insert_idx = prev_index;
                var i: u32 = 0;
                while (i < entries_count) : (i += 1) {
                    const entry_term = try reader.takeInt(u64, .little);
                    const entry_len = try reader.takeInt(u32, .little);
                    const entry_payload = payload[reader.seek .. reader.seek + entry_len];
                    try reader.discardAll(@intCast(entry_len));

                    if (insert_idx < self.log.items.len) {
                        if (self.log.items[insert_idx].term != entry_term) {
                            // Truncate conflicts
                            while (self.log.items.len > insert_idx) {
                                const popped = self.log.pop();
                                self.allocator.free(popped.?.payload);
                            }
                            try self.log.append(.{
                                .term = entry_term,
                                .payload = try self.allocator.dupe(u8, entry_payload),
                            });
                        }
                    } else {
                        try self.log.append(.{
                            .term = entry_term,
                            .payload = try self.allocator.dupe(u8, entry_payload),
                        });
                    }
                    insert_idx += 1;
                }

                // Apply commit index changes
                if (leader_commit > self.commit_index) {
                    self.commit_index = @min(leader_commit, self.log.items.len);
                    try self.applyCommittedEntries();
                }
            }
        }

        var resp_buf = try self.allocator.alloc(u8, 21);
        std.mem.writeInt(u32, resp_buf[0..4], self.db.node_id, .little);
        std.mem.writeInt(u64, resp_buf[4..12], self.current_term, .little);
        resp_buf[12] = success;
        std.mem.writeInt(u64, resp_buf[13..21], self.log.items.len, .little);
        return resp_buf;
    }

    pub fn handleAppendEntriesResp(self: *Raft, payload: []const u8) !void {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);

        const follower_id = std.mem.readInt(u32, payload[0..4], .little);
        const term = std.mem.readInt(u64, payload[4..12], .little);
        const success = payload[12];
        const match_idx = std.mem.readInt(u64, payload[13..21], .little);

        if (term > self.current_term) {
            self.current_term = term;
            self.role = .follower;
            self.voted_for = null;
            return;
        }

        if (self.role == .leader and term == self.current_term) {
            if (success == 1) {
                try self.next_index.put(follower_id, match_idx + 1);
                try self.match_index.put(follower_id, match_idx);

                // Update commit index by finding majority match_index
                var N = self.log.items.len;
                while (N > self.commit_index) : (N -= 1) {
                    if (self.log.items[N - 1].term == self.current_term) {
                        var count: usize = 1; // Count self
                        var it = self.match_index.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.* >= N) {
                                count += 1;
                            }
                        }
                        const total_nodes = self.db.peers.count() + 1;
                        const majority = (total_nodes / 2) + 1;
                        if (count >= majority) {
                            self.commit_index = N;
                            try self.applyCommittedEntries();
                            break;
                        }
                    }
                }
            } else {
                // Backtrack next_index
                const current_next = self.next_index.get(follower_id) orelse 1;
                if (current_next > 1) {
                    try self.next_index.put(follower_id, current_next - 1);
                }
            }
        }
    }

    fn applyCommittedEntries(self: *Raft) !void {
        while (self.last_applied < self.commit_index) {
            self.last_applied += 1;
            const entry = self.log.items[self.last_applied - 1];
            // Process the sync payload in the database state engine
            try self.db.processMutation(entry.payload, true);
        }
    }

    pub fn proposeMutation(self: *Raft, payload: []const u8) !void {
        var is_leader = false;
        var leader_id_opt: ?u32 = null;

        {
            self.mutex.lockUncancelable(self.db.io);
            is_leader = (self.role == .leader);
            leader_id_opt = self.leader_id;
            self.mutex.unlock(self.db.io);
        }

        if (is_leader) {
            // Assign timestamp/node_id and convert to sync payload
            const sync_payload = try mutationToSyncPayload(self.allocator, self.db.node_id, self.db.io, payload);
            defer self.allocator.free(sync_payload);

            var entry_index: usize = 0;
            {
                self.mutex.lockUncancelable(self.db.io);
                defer self.mutex.unlock(self.db.io);

                try self.log.append(.{
                    .term = self.current_term,
                    .payload = try self.allocator.dupe(u8, sync_payload),
                });
                entry_index = self.log.items.len;
            }

            // Trigger log replication immediately
            try self.sendHeartbeats();

            // Wait until entry is committed
            while (true) {
                {
                    self.mutex.lockUncancelable(self.db.io);
                    defer self.mutex.unlock(self.db.io);
                    if (self.commit_index >= entry_index) {
                        break;
                    }
                    if (self.role != .leader) {
                        return error.LostLeadership;
                    }
                }
                try std.Io.sleep(self.db.io, std.Io.Duration.fromMilliseconds(5), .awake);
            }
        } else {
            // If follower, forward mutation to leader
            if (leader_id_opt) |leader_id| {
                var leader_peer_opt: ?db_mod.Peer = null;
                {
                    self.db.peers_mutex.lockUncancelable(self.db.io);
                    defer self.db.peers_mutex.unlock(self.db.io);
                    if (self.db.peers.get(leader_id)) |p| {
                        leader_peer_opt = p;
                    }
                }

                if (leader_peer_opt) |leader_peer| {
                    const stream = try std.Io.net.IpAddress.connect(&leader_peer.address, self.db.io, .{ .mode = .stream });
                    defer stream.close(self.db.io);

                    const header = protocol.Header{
                        .msg_type = .mutation,
                        .stream_id = 0,
                        .payload_len = @intCast(payload.len),
                        .sequence = 0,
                    };

                    var write_buf: [1024]u8 = undefined;
                    var conn_writer = stream.writer(self.db.io, &write_buf);
                    const writer = &conn_writer.interface;
                    try writer.writeAll(std.mem.asBytes(&header));
                    try writer.writeAll(payload);
                    try writer.flush();
                    return;
                }
            }
            return error.NoLeaderAvailable;
        }
    }
};

pub fn mutationToSyncPayload(allocator: std.mem.Allocator, node_id: u32, io: std.Io, mutation_payload: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(mutation_payload);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    const timestamp = std.Io.Clock.now(.real, io).toMilliseconds();

    while (reader.seek < reader.end) {
        const table_id = reader.takeInt(u16, .little) catch break;
        const pk_len = try reader.takeInt(u16, .little);
        const pk = mutation_payload[reader.seek .. reader.seek + pk_len];
        try reader.discardAll(@intCast(pk_len));

        try writer.writeInt(u16, table_id, .little);
        try writer.writeInt(u16, @intCast(pk.len), .little);
        try writer.writeAll(pk);

        const mutation_count = try reader.takeInt(u8, .little);
        try writer.writeByte(mutation_count);

        var i: u8 = 0;
        while (i < mutation_count) : (i += 1) {
            const col_idx = try reader.takeInt(u8, .little);
            const op = try reader.takeInt(u8, .little);

            const val_len = try reader.takeInt(u16, .little);
            const val = mutation_payload[reader.seek .. reader.seek + val_len];
            try reader.discardAll(@intCast(val_len));

            try writer.writeByte(col_idx);
            try writer.writeByte(op);
            try writer.writeInt(i64, timestamp, .little);
            try writer.writeInt(u32, node_id, .little);
            try writer.writeInt(u16, @intCast(val.len), .little);
            try writer.writeAll(val);
        }
    }

    return try allocator.dupe(u8, aw.written());
}
