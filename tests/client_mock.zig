const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

pub fn main() !void {
    const address = try net.Address.resolveIp("127.0.0.1", 9000);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const writer = stream.writer();

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

    std.debug.print("Frame sent successfully\n", .{});
}
