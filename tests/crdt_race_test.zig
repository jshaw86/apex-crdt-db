const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("\n=== STARTING CRDT CONCURRENCY & RACE CONDITION TESTS ===\n", .{});

    // 1. Test LWW Register deterministic resolution and tie-breaking on Node 1 (port 9000)
    std.debug.print("\n--- Testing LWW Register Tie-Breaking ---\n", .{});
    
    // Write Alice (t=1000, Node 1)
    try sendLwwSync(9000, "race_lww", "Alice", 1000, 1);
    // Write Bob (t=1000, Node 2) - same timestamp, higher Node ID
    try sendLwwSync(9000, "race_lww", "Bob", 1000, 2);

    // Verify Bob won because Node ID 2 > 1
    const val1 = try queryColumnValue(allocator, 9000, "race_lww", 0);
    defer allocator.free(val1);
    std.debug.print("LWW Same-timestamp write (Alice node=1 vs Bob node=2): Resolved = '{s}' (Expected: 'Bob')\n", .{val1});
    try std.testing.expectEqualStrings("Bob", val1);

    // Write Charlie (t=999, Node 3) - lower timestamp, should be ignored
    try sendLwwSync(9000, "race_lww", "Charlie", 999, 3);
    const val2 = try queryColumnValue(allocator, 9000, "race_lww", 0);
    defer allocator.free(val2);
    std.debug.print("LWW Lower-timestamp write (Charlie t=999): Resolved = '{s}' (Expected: 'Bob')\n", .{val2});
    try std.testing.expectEqualStrings("Bob", val2);

    // Write David (t=1001, Node 1) - higher timestamp, should win
    try sendLwwSync(9000, "race_lww", "David", 1001, 1);
    const val3 = try queryColumnValue(allocator, 9000, "race_lww", 0);
    defer allocator.free(val3);
    std.debug.print("LWW Higher-timestamp write (David t=1001): Resolved = '{s}' (Expected: 'David')\n", .{val3});
    try std.testing.expectEqualStrings("David", val3);

    // 2. Test PN Counter Commutative Concurrent Writes
    std.debug.print("\n--- Testing PN Counter Concurrency & Replication ---\n", .{});
    
    var buf_inc: [8]u8 = undefined;
    
    // Add 10 to Node 1
    std.mem.writeInt(i64, &buf_inc, 10, .little);
    try sendClientMutation(9000, "race_pn", 1, 0x02, &buf_inc);
    std.debug.print("Sent Mutation: +10 to Node 1\n", .{});

    // Add 20 to Node 2
    std.mem.writeInt(i64, &buf_inc, 20, .little);
    try sendClientMutation(9001, "race_pn", 1, 0x02, &buf_inc);
    std.debug.print("Sent Mutation: +20 to Node 2\n", .{});

    // 3. Test AW Set Add-Wins Concurrent Writes
    std.debug.print("\n--- Testing AW Set Concurrency & Replication ---\n", .{});
    
    // Add Apple to Node 1
    try sendClientMutation(9000, "race_aw", 2, 0x03, "Apple");
    std.debug.print("Sent Mutation: ADD Apple to Node 1\n", .{});

    // Add Banana to Node 2
    try sendClientMutation(9001, "race_aw", 2, 0x03, "Banana");
    std.debug.print("Sent Mutation: ADD Banana to Node 2\n", .{});

    std.debug.print("\nWaiting 6 seconds for replication anti-entropy loop to propagate...\n", .{});
    std.time.sleep(6 * std.time.ns_per_s);

    // Verify PN Counter Convergence across all nodes
    const ports = [_]u16{ 9000, 9001, 9002 };
    for (ports, 1..) |port, node_idx| {
        const pn_val = try queryColumnValue(allocator, port, "race_pn", 1);
        defer allocator.free(pn_val);
        std.debug.print("Node {} (port {}): PN Counter Value = '{s}' (Expected: '30')\n", .{ node_idx, port, pn_val });
        try std.testing.expectEqualStrings("30", pn_val);
    }

    // Verify AW Set Convergence across all nodes
    for (ports, 1..) |port, node_idx| {
        const aw_val = try queryColumnValue(allocator, port, "race_aw", 2);
        defer allocator.free(aw_val);
        std.debug.print("Node {} (port {}): AW Set Value = '{s}' (Expected: contains 'Apple' and 'Banana')\n", .{ node_idx, port, aw_val });
        try std.testing.expect(std.mem.indexOf(u8, aw_val, "Apple") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw_val, "Banana") != null);
    }

    std.debug.print("\n=== ALL CRDT CONCURRENCY & RACE CONDITION TESTS PASSED ===\n\n", .{});
}

fn sendLwwSync(port: u16, row: []const u8, val: []const u8, timestamp: i64, node_id: u32) !void {
    const address = try net.Address.resolveIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();
    const writer = stream.writer();

    var payload_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer payload_buf.deinit();
    const p_writer = payload_buf.writer();

    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, @intCast(row.len), .little);
    try p_writer.writeAll(row);
    try p_writer.writeByte(1);
    try p_writer.writeByte(0); // Col 0
    try p_writer.writeByte(1); // Op SET
    try p_writer.writeInt(i64, timestamp, .little);
    try p_writer.writeInt(u32, node_id, .little);
    try p_writer.writeInt(u16, @intCast(val.len), .little);
    try p_writer.writeAll(val);

    const header = protocol.Header{
        .msg_type = .sync,
        .stream_id = 1,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);
}

fn sendClientMutation(port: u16, row: []const u8, col: u8, op: u8, val: []const u8) !void {
    const address = try net.Address.resolveIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();
    const writer = stream.writer();

    var payload_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer payload_buf.deinit();
    const p_writer = payload_buf.writer();

    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, @intCast(row.len), .little);
    try p_writer.writeAll(row);
    try p_writer.writeByte(1);
    try p_writer.writeByte(col);
    try p_writer.writeByte(op);
    try p_writer.writeInt(u16, @intCast(val.len), .little);
    try p_writer.writeAll(val);

    const header = protocol.Header{
        .msg_type = .mutation,
        .stream_id = 1,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);
}

fn queryColumnValue(allocator: std.mem.Allocator, port: u16, row_name: []const u8, col_idx: u8) ![]const u8 {
    const address = try net.Address.resolveIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const writer = stream.writer();
    const reader = stream.reader();

    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    const p_writer = payload_buf.writer();
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, @intCast(row_name.len), .little);
    try p_writer.writeAll(row_name);

    const header = protocol.Header{
        .msg_type = .query,
        .stream_id = 42,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);

    var resp_header_buf: [protocol.Header.SIZE]u8 = undefined;
    _ = try reader.readAtLeast(&resp_header_buf, protocol.Header.SIZE);
    const resp_header = std.mem.bytesToValue(protocol.Header, &resp_header_buf);

    if (resp_header.msg_type != .query_response) return error.WrongMsgType;

    const resp_payload = try allocator.alloc(u8, resp_header.payload_len);
    defer allocator.free(resp_payload);
    _ = try reader.readAtLeast(resp_payload, resp_header.payload_len);

    if (resp_payload[0] == 0x01) return error.RowNotFound;

    const row_count = std.mem.readInt(u32, resp_payload[1..5], .little);
    if (row_count == 0) return error.RowNotFound;

    var pos: usize = 5;
    const pk_len = std.mem.readInt(u16, resp_payload[pos..][0..2], .little);
    pos += 2 + pk_len;

    const cell_count = resp_payload[pos];
    pos += 1;

    if (col_idx >= cell_count) return error.ColNotFound;

    var i: u8 = 0;
    while (i < cell_count) : (i += 1) {
        const col_type = resp_payload[pos];
        pos += 1;
        const val_len = std.mem.readInt(u16, resp_payload[pos..][0..2], .little);
        pos += 2;
        const val = resp_payload[pos .. pos + val_len];
        pos += val_len;

        if (i == col_idx) {
            _ = col_type;
            return try allocator.dupe(u8, val);
        }
    }
    return error.ColNotFound;
}
