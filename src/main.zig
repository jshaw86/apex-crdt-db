const std = @import("std");
const net = std.net;
const protocol = @import("protocol/frame.zig");
const db_mod = @import("db.zig");
const engine = @import("storage/engine.zig");
const replication = @import("replication/manager.zig");
const gossip_mod = @import("replication/gossip.zig");
const schema_mod = @import("schema/engine.zig");
const schema_parser = @import("schema/parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse CLI args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const port = if (args.next()) |p| try std.fmt.parseInt(u16, p, 10) else 9000;
    const node_id = if (args.next()) |id| try std.fmt.parseInt(u32, id, 10) else 1;
    const seed_port = if (args.next()) |p| try std.fmt.parseInt(u16, p, 10) else null;

    var db = db_mod.Database.init(allocator, node_id);
    defer db.deinit();

    // Setup seed peer
    if (seed_port) |p| {
        const seed_addr = try net.Address.resolveIp("127.0.0.1", p);
        try db.addOrUpdatePeer(0, seed_addr);
        std.debug.print("Seed node configured: {}\n", .{seed_addr});
    }

    // --- SCHEMA SETUP (Bootstrapping) ---
    var parser = schema_parser.Parser.init(allocator);
    const bootstrap_sql = "CREATE TABLE chatroom { name: TEXT, total_chats: INT, members: SET }";
    const chat_schema = try parser.parse(5, bootstrap_sql);
    try db.registerSchema(chat_schema);
    // ------------------------------------

    // Start Managers
    var gossip_mgr = gossip_mod.GossipManager.init(allocator, &db, port);
    const gossip_thread = try gossip_mgr.start();
    gossip_thread.detach();

    var rep_manager = replication.ReplicationManager.init(allocator, &db);
    const sync_thread = try rep_manager.start();
    sync_thread.detach();

    var janitor = @import("storage/janitor.zig").Janitor.init(&db);
    const janitor_thread = try janitor.start();
    janitor_thread.detach();

    const address = try net.Address.resolveIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Apex Node {} listening on {}\n", .{ node_id, address });

    while (true) {
        const conn = try server.accept();
        handleConnection(allocator, &db, &gossip_mgr, &parser, conn) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, db: *db_mod.Database, gossip_mgr: *gossip_mod.GossipManager, parser: *schema_parser.Parser, conn: net.Server.Connection) !void {
    defer conn.stream.close();
    const reader = conn.stream.reader();

    while (true) {
        var header_buf: [protocol.Header.SIZE]u8 = undefined;
        const bytes_read = try reader.readAtLeast(&header_buf, protocol.Header.SIZE);
        if (bytes_read == 0) break;

        const header = std.mem.bytesToValue(protocol.Header, &header_buf);
        if (!header.validate()) return error.InvalidProtocol;

        const payload = try allocator.alloc(u8, header.payload_len);
        defer allocator.free(payload);
        _ = try reader.readAtLeast(payload, header.payload_len);

        if (header.msg_type == .mutation) {
            try db.processMutation(payload, false);
        } else if (header.msg_type == .sync) {
            try db.processMutation(payload, true);
        } else if (header.msg_type == .gossip) {
            try gossip_mgr.handleGossip(payload);
        } else if (header.msg_type == .admin) {
            // Admin payload for schema submission: [TableID: u16][SQL: Bytes]
            var fbs = std.io.fixedBufferStream(payload);
            const p_reader = fbs.reader();
            const table_id = try p_reader.readInt(u16, .little);
            const sql = payload[fbs.pos..];
            
            const new_schema = try parser.parse(table_id, sql);
            try db.registerSchema(new_schema);
        } else if (header.msg_type == .query) {
            var response_payload = std.ArrayList(u8).init(allocator);
            defer response_payload.deinit();
            try db.processQuery(payload, &response_payload);
            const response_header = protocol.Header{
                .msg_type = .query_response,
                .stream_id = header.stream_id,
                .payload_len = @intCast(response_payload.items.len),
                .sequence = header.sequence,
            };
            try conn.stream.writer().writeAll(std.mem.asBytes(&response_header));
            try conn.stream.writer().writeAll(response_payload.items);
        }
    }
}
