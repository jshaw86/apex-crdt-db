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

    const table_id: u16 = 10;
    const sql = "CREATE TABLE users { display_name: TEXT, karma: INT, friends: SET }";
    
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const p_writer = &aw.writer;

    try p_writer.writeInt(u16, table_id, .little);
    try p_writer.writeAll(sql);

    const header = protocol.Header{
        .msg_type = .admin,
        .stream_id = 0,
        .payload_len = @intCast(aw.written().len),
        .sequence = 1,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(aw.written());
    try writer.flush();

    std.debug.print("Admin message sent: CREATE TABLE users\n", .{});

    // Now send a mutation for the newly created table!
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake);

    aw.clearRetainingCapacity();
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
        .payload_len = @intCast(aw.written().len),
        .sequence = 2,
    };

    try writer.writeAll(std.mem.asBytes(&mut_header));
    try writer.writeAll(aw.written());
    try writer.flush();
    
    std.debug.print("Mutation sent to new table 'users'\n", .{});
}
