const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

pub fn main() !void {
    const address = try net.Address.resolveIp("127.0.0.1", 9000);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const writer = stream.writer();

    // Construct a Mutation Payload
    // [TableID: u16] = 5
    // [PK_Len: u16] = 4 ("user")
    // [PK: user]
    // [MutationCount: u8] = 1
    //   [ColIdx: u8] = 0 (name)
    //   [Op: u8] = 1 (SET)
    //   [ValLen: u16] = 5 ("Alice")
    //   [Val: Alice]

    var payload_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer payload_buf.deinit();

    const p_writer = payload_buf.writer();
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("user");
    try p_writer.writeByte(1);
    try p_writer.writeByte(0); // Col 0
    try p_writer.writeByte(1); // Op SET
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeAll("Alice");

    const header = protocol.Header{
        .msg_type = .mutation,
        .stream_id = 1,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);

    std.debug.print("Mutation sent: Alice -> user\n", .{});
}
