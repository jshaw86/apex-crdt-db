const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try net.IpAddress.parse("127.0.0.1", 9000);
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    const writer = &conn_writer.interface;

    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();

    const p_writer = &aw.writer;
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
        .payload_len = @intCast(aw.written().len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(aw.written());
    try writer.flush();

    std.debug.print("Mutation sent: Alice -> user\n", .{});
}
