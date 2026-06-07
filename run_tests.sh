#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== 1. Building Docker Images ===${NC}"
docker compose build

echo -e "\n${BLUE}=== 2. Starting Cluster ===${NC}"
docker compose down --remove-orphans
docker compose up -d

# Function to clean up containers on exit
cleanup() {
    echo -e "\n${YELLOW}=== Cleaning up containers ===${NC}"
    docker compose down
}
trap cleanup EXIT

echo -e "\n${YELLOW}Waiting 5 seconds for nodes to start and peer discovery to complete via Gossip...${NC}"
sleep 5

echo -e "\n${BLUE}=== 3. Running Schema and Mutation Tests ===${NC}"

echo -e "\n${YELLOW}Running: schema_test (Send mixed mutation to Node 1)${NC}"
docker compose exec -T node1 /app/zig-out/bin/schema_test

echo -e "\n${YELLOW}Running: aw_set_test (Add members to chatroom on Node 1)${NC}"
docker compose exec -T node1 /app/zig-out/bin/aw_set_test

echo -e "\n${YELLOW}Running: dynamic_schema_test (Register new 'users' table schema on Node 1)${NC}"
docker compose exec -T node1 /app/zig-out/bin/dynamic_schema_test

echo -e "\n${YELLOW}Running: mutation_test (Set user name to Alice on Node 1)${NC}"
docker compose exec -T node1 /app/zig-out/bin/mutation_test

echo -e "\n${YELLOW}Running: query_test (Query Node 1 to verify user=Alice)${NC}"
docker compose exec -T node1 /app/zig-out/bin/query_test 9000

echo -e "\n${BLUE}=== 4. Testing Replication (gossip & anti-entropy push loop) ===${NC}"

echo -e "\n${YELLOW}Running: replication_test_client (Update user -> Bob on Node 1)${NC}"
docker compose exec -T node1 /app/zig-out/bin/replication_test_client

echo -e "\n${YELLOW}Waiting 6 seconds for replication anti-entropy loop to push deltas to peer nodes...${NC}"
sleep 6

echo -e "\n${YELLOW}Querying Node 2 (port 9001) to verify user=Bob has replicated...${NC}"
docker compose exec -T node1 /app/zig-out/bin/query_test 9001

echo -e "\n${YELLOW}Querying Node 3 (port 9002) to verify user=Bob has replicated...${NC}"
docker compose exec -T node1 /app/zig-out/bin/query_test 9002

echo -e "\n${BLUE}=== 5. Running Host-less Unit Tests ===${NC}"
docker compose exec -T node1 zig build test

echo -e "\n${BLUE}=== 6. Running CRDT Race and Concurrency Integration Tests ===${NC}"
docker compose exec -T node1 /app/zig-out/bin/crdt_race_test

echo -e "\n${GREEN}=== All tests executed successfully! ===${NC}"
