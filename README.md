# Apex CRDT Database

A lightweight, high-performance, distributed, schema-aware CRDT (Conflict-Free Replicated Data Type) database written in Zig (0.13.0). It supports dynamic clustering, gossip-based peer discovery, automatic delta replication, and row-level TTL.

## Features

- **Conflict-Free Replicated Data Types (CRDTs)**:
  - **LWW Register (Last-Write-Wins)**: For simple values with tie-breaking using monotonic timestamps and Node IDs.
  - **PN Counter (Positive-Negative Counter)**: For commutative numeric increments and decrements.
  - **AW Set (Add-Wins Set)**: Dot-based set replication preventing lost updates.
- **Schema Registry & Parser**: A dynamic SQL-like parser to declare tables with typed column CRDTs.
- **Clustering & Gossip Protocol**: Nodes register with a seed peer and dynamically discover other peers via a Gossip protocol loop.
- **Push Delta Replication**: Background anti-entropy replication periodically syncs local Oplog deltas to peers.
- **Row-level TTL**: Background janitor service automatically purges expired rows.
- **High Performance Wire Protocol**: Low-overhead binary protocol optimized for zero-copy deserialization in Zig.

---

## Directory Structure

```text
├── docs/                   # Architectural and wire protocol documentation
├── src/
│   ├── main.zig            # Application entrypoint & CLI parser
│   ├── db.zig              # Central Database controller (oplog, routing, peers)
│   ├── protocol/           # Binary frame headers and protocol envelopes
│   ├── replication/        # Gossip and delta-based replication managers
│   ├── schema/             # Schema parsing and table registries
│   └── storage/            # Memory engine, CRDT cells, and TTL janitor
├── tests/                  # Integration tests / client mocks
├── Dockerfile              # Multi-arch compilation environment (Zig 0.13.0)
├── docker-compose.yml      # Local 3-node cluster compose file
└── run_tests.sh            # Automated integration test runner
```

---

## Wire Protocol (Apex Protocol)

Every message starts with a fixed 20-byte binary header:

| Offset | Length | Type | Name | Description |
| :--- | :--- | :--- | :--- | :--- |
| 0 | 1 | u8 | Magic | `0xAX` (Apex Protocol indicator) |
| 1 | 1 | u8 | Version | Protocol version (`0x01`) |
| 2 | 1 | u8 | Type | Msg Type (Query, Mutation, Gossip, Sync, Admin) |
| 3 | 1 | u8 | Flags | Header flags (e.g. compression) |
| 4 | 4 | u32 | StreamID | For multiplexing requests |
| 8 | 4 | u32 | Length | Payload length |
| 12 | 8 | u64 | Sequence | Monotonic sequence number |

---

## Local Development

### Prerequisites

- [Zig Compiler](https://ziglang.org/download/) (v0.13.0)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for running multi-node tests)

### Build the Project
Compile the server and all client tests:
```bash
zig build
```
This builds all executables into the `zig-out/bin/` directory.

### Run a Local Database Instance
```bash
# Usage: zig-out/bin/database <port> <node_id> [seed_port]
zig-out/bin/database 9000 1
```

---

## Docker Compose Cluster

We provide a Docker Compose configuration that runs a 3-node database cluster. The containers share a network namespace, enabling gossip discovery and replication across localhost loops (`127.0.0.1`).

### Start the Cluster
```bash
docker compose up -d
```
This launches:
- **Node 1**: Listening on port `9000` (Seed Node)
- **Node 2**: Listening on port `9001` (Connects to Node 1)
- **Node 3**: Listening on port `9002` (Connects to Node 1)

### Run Integration Tests
We provide a helper script to build images, spin up the cluster, run operations, wait for delta replication, and query replica nodes to verify successful replication:
```bash
./run_tests.sh
```

### Manual Verification using client.py

Since the database uses a custom TCP binary protocol for low-overhead wire serialization, standard HTTP `curl` commands cannot communicate with it directly. To make manual testing simple, we provide a Python CLI helper [client.py](file:///Users/jordan.shaw/Development/zig/database/client.py) in the root directory.

Ensure the 3-node cluster is running:
```bash
docker compose up -d
```

You can then run the following verification sequence:

1. **Register a Custom Table Schema on Node 1 (port 9000)**:
   ```bash
   python3 client.py schema 9000 10 "CREATE TABLE users { name: TEXT, karma: INT, friends: SET }"
   ```

2. **Send Mutations (Writes) to Node 1**:
   - Write to the TEXT column (`name`, Column 0):
     ```bash
     python3 client.py mutate 9000 10 bob1 0 set "Bob Smith"
     ```
   - Increment the INT counter (`karma`, Column 1):
     ```bash
     python3 client.py mutate 9000 10 bob1 1 add 150
     ```
   - Add items to the SET column (`friends`, Column 2):
     ```bash
     python3 client.py mutate 9000 10 bob1 2 add-item Alice
     python3 client.py mutate 9000 10 bob1 2 add-item Charlie
     ```

3. **Query Node 1 to verify local write state**:
   ```bash
   python3 client.py query 9000 10 bob1
   ```

4. **Verify Propagation (Replication) on Peer Nodes**:
   Wait 6 seconds for the anti-entropy background replication loop to trigger, then query Node 2 (port 9001) and Node 3 (port 9002):
   ```bash
   python3 client.py query 9001 10 bob1
   python3 client.py query 9002 10 bob1
   ```
