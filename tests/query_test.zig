const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip binary name

    const port = if (args.next()) |p| try std.fmt.parseInt(u16, p, 10) else 9000;
    const address = try net.Address.resolveIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const writer = stream.writer();
    const reader = stream.reader();

    // 1. Send a Query for PK "user" in Table 5
    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();

    const p_writer = payload_buf.writer();
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("user");

    const header = protocol.Header{
        .msg_type = .query,
        .stream_id = 42,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);

    // 2. Read the Response
    var resp_header_buf: [protocol.Header.SIZE]u8 = undefined;
    _ = try reader.readAtLeast(&resp_header_buf, protocol.Header.SIZE);
    const resp_header = std.mem.bytesToValue(protocol.Header, &resp_header_buf);

    if (resp_header.msg_type != .query_response) {
        std.debug.print("Expected query_response, got {s}\n", .{@tagName(resp_header.msg_type)});
        return;
    }

    const resp_payload = try allocator.alloc(u8, resp_header.payload_len);
    defer allocator.free(resp_payload);
    _ = try reader.readAtLeast(resp_payload, resp_header.payload_len);

    // 3. Parse Response [Status: u8][RowCount: u32]
    if (resp_payload[0] == 0x01) {
        std.debug.print("Row not found.\n", .{});
    } else {
        const row_count = std.mem.readInt(u32, resp_payload[1..][0..4], .little);
        std.debug.print("Query successful. Rows returned: {}\n", .{row_count});

        var pos: usize = 5;
        var r: u32 = 0;
        while (r < row_count) : (r += 1) {
            const pk_len = std.mem.readInt(u16, resp_payload[pos..][0..2], .little);
            pos += 2;
            const pk = resp_payload[pos .. pos + pk_len];
            pos += pk_len;

            const cell_count = resp_payload[pos];
            pos += 1;
            std.debug.print("Row '{s}' has {} columns:\n", .{ pk, cell_count });

            var i: u8 = 0;
            while (i < cell_count) : (i += 1) {
                const col_type = resp_payload[pos];
                pos += 1;
                const val_len = std.mem.readInt(u16, resp_payload[pos..][0..2], .little);
                pos += 2;
                const val = resp_payload[pos .. pos + val_len];
                pos += val_len;

                std.debug.print("  Col {}: (type={}) val='{s}'\n", .{ i, col_type, val });
            }
        }
    }
}
