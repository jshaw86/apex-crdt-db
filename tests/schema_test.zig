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

    // Mutation for "user"
    try p_writer.writeInt(u16, 5, .little); // Table 5
    try p_writer.writeInt(u16, 4, .little);
    try p_writer.writeAll("user");
    
    try p_writer.writeByte(2); // TWO mutations
    
    // Mutation 1: Col 0 (name) -> SET Alice
    try p_writer.writeByte(0); 
    try p_writer.writeByte(1); // Op SET
    try p_writer.writeInt(u16, 5, .little);
    try p_writer.writeAll("Alice");

    // Mutation 2: Col 1 (total_chats) -> ADD 1
    try p_writer.writeByte(1);
    try p_writer.writeByte(2); // Op ADD
    try p_writer.writeInt(u16, 8, .little); // 8 bytes for i64
    try p_writer.writeInt(i64, 1, .little);

    const header = protocol.Header{
        .msg_type = .mutation,
        .stream_id = 1,
        .payload_len = @intCast(aw.written().len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(aw.written());
    try writer.flush();

    std.debug.print("Sent mixed mutation: Name=Alice, total_chats+=1\n", .{});
}
