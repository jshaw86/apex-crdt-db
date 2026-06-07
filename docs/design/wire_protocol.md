# Wire Protocol Design: "Apex" (Working Name)

A high-performance, binary, multiplexed protocol designed for schema-aware CRDT operations.

## 1. Frame Structure (The Envelope)
Every packet starts with a fixed-size header.

| Offset | Length | Type | Name | Description |
| :--- | :--- | :--- | :--- | :--- |
| 0 | 1 | u8 | Magic | `0xAX` (Apex Protocol) |
| 1 | 1 | u8 | Version | Protocol version (e.g., `0x01`) |
| 2 | 1 | u8 | Type | Message Type (Query, Update, Auth, Sync, Admin) |
| 3 | 1 | u8 | Flags | Compression, Encryption, etc. |
| 4 | 4 | u32 | StreamID | For multiplexing requests over one connection. |
| 8 | 4 | u32 | Length | Length of the following Payload. |
| 12 | 8 | u64 | Sequence | Monotonic sequence number for the stream. |

## 2. Operation Types (The Payload)

### Update (Write Path)
Since we have a schema, we don't send the whole row. We send **Delta-Mutations**.

```
[TableID: u16]
[PrimaryKey: VarInt/Bytes]
[MutationCount: u8]
  [ColumnIndex: u8]
  [OpCode: u8] (INC, DEC, SET, ADD, REMOVE)
  [Value: Type-specific]
```

*Example: `UPDATE chatroom SET total_chats += 1 WHERE user_id = ...`*
- `TableID`: 5 (Chatroom)
- `PK`: 16-byte UUID
- `Count`: 1
- `ColIdx`: 2 (total_chats)
- `Op`: `0x01` (INC)
- `Val`: `0x00000001` (u32)

### Sync (Node-to-Node)
Replication uses a **State-Based** or **Delta-Based** sync.
- Nodes exchange **Vector Clocks** to determine what data is missing.
- The wire format for Sync includes the CRDT Metadata (the "Dots" or "Timestamps") that standard clients don't see.

## 3. Serialization
- **Little Endian** by default (Native to Zig/x86/ARM).
- **VarInts** for lengths to save bytes on small strings/IDs.
- **Zero-Copy Readiness**: The layout should allow the Zig server to cast a buffer slice directly to a `struct` (using `@ptrCast` or `extern struct`) without expensive parsing.

## 4. Why this works for CRDTs
By sending an `OpCode` (like `INC`) instead of the final value, the database can apply the increment to its local CRDT state. This ensures that even if updates arrive out of order from different nodes, the final state converges.
