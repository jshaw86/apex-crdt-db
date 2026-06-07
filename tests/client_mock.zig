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

    const message = "Hello, Apex!";
    const header = protocol.Header{
        .msg_type = .query,
        .stream_id = 1,
        .payload_len = @intCast(message.len),
        .sequence = 100,
    };

    // Write header
    try writer.writeAll(std.mem.asBytes(&header));
    // Write payload
    try writer.writeAll(message);
    try writer.flush();

    std.debug.print("Frame sent successfully\n", .{});
}
