const std = @import("std");

pub const MessageType = enum(u8) {
    query = 0x01,
    mutation = 0x02,
    sync = 0x03,
    auth = 0x04,
    admin = 0x05,
    query_response = 0x06,
    gossip = 0x07,
    raft_request_vote = 0x08,
    raft_request_vote_resp = 0x09,
    raft_append_entries = 0x0a,
    raft_append_entries_resp = 0x0b,
};

/// The fixed-size header for all Apex protocol messages.
/// Total size: 20 bytes.
pub const Header = extern struct {
    magic: u8 = 0x41, // 'A'
    version: u8 = 0x01,
    msg_type: MessageType,
    flags: u8 = 0,
    stream_id: u32,
    payload_len: u32,
    sequence: u64,

    pub const SIZE = @sizeOf(Header);

    pub fn validate(self: Header) bool {
        return self.magic == 0x41 and self.version == 0x01;
    }
};

pub const Frame = struct {
    header: Header,
    payload: []u8,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};
