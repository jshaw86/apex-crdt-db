const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const address = try net.Address.resolveIp("127.0.0.1", 9000);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const writer = stream.writer();

    const table_id: u16 = 10;
    const sql = "CREATE TABLE users { display_name: TEXT, karma: INT, friends: SET }";
    
    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    const p_writer = payload_buf.writer();

    try p_writer.writeInt(u16, table_id, .little);
    try p_writer.writeAll(sql);

    const header = protocol.Header{
        .msg_type = .admin,
        .stream_id = 0,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);

    std.debug.print("Admin message sent: CREATE TABLE users\n", .{});

    // Now send a mutation for the newly created table!
    std.time.sleep(100 * std.time.ns_per_ms);

    payload_buf.clearRetainingCapacity();
    try p_writer.writeInt(u16, table_id, .little);
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("bob1");
    try p_writer.writeByte(1); // One mutation
    try p_writer.writeByte(1); // Col 1 (karma)
    try p_writer.writeByte(2); // Op ADD
    try p_writer.writeInt(u16, 8, .little);
    try p_writer.writeInt(i64, 500, .little);

    const mut_header = protocol.Header{
        .msg_type = .mutation,
        .stream_id = 1,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 2,
    };

    try writer.writeAll(std.mem.asBytes(&mut_header));
    try writer.writeAll(payload_buf.items);
    
    std.debug.print("Mutation sent to new table 'users'\n", .{});
}
