const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const io = init.io;

    const address = try net.IpAddress.parse("127.0.0.1", 9000);
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    const writer = &conn_writer.interface;

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const p_writer = &aw.writer;

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
        .payload_len = @intCast(aw.written().len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(aw.written());
    try writer.flush();

    std.debug.print("Sent AW-Set mutations: Add Jordan, Add Alex\n", .{});
}
