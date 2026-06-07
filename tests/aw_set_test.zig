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

    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    const p_writer = payload_buf.writer();

    // Table 5 (chatroom), Row "user"
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("user");
    
    try p_writer.writeByte(2); // Two mutations
    
    // Mutation 1: Col 2 (members) -> ADD "Jordan"
    try p_writer.writeByte(2); 
    try p_writer.writeByte(3); // Op ADD
    try p_writer.writeInt(u16, 6, .little);
    try p_writer.writeAll("Jordan");

    // Mutation 2: Col 2 (members) -> ADD "Alex"
    try p_writer.writeByte(2);
    try p_writer.writeByte(3); // Op ADD
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("Alex");

    const header = protocol.Header{
        .msg_type = .mutation,
        .stream_id = 1,
        .payload_len = @intCast(payload_buf.items.len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload_buf.items);

    std.debug.print("Sent AW-Set mutations: Add Jordan, Add Alex\n", .{});
}
