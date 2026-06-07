#!/usr/bin/env python3
import sys
import socket
import struct

HEADER_FORMAT = "<BBBBIi4xQ"
HEADER_SIZE = 24
MAGIC = 0x41  # 'A'
VERSION = 0x01

MSG_QUERY = 0x01
MSG_MUTATION = 0x02
MSG_ADMIN = 0x05
MSG_QUERY_RESPONSE = 0x06

OP_LWW_SET = 0x01
OP_PN_ADD = 0x02
OP_SET_ADD = 0x03
OP_SET_REMOVE = 0x04

def print_usage():
    print("Apex CRDT Database CLI Client Utility")
    print("Usage:")
    print("  python3 client.py schema <port> <table_id> <sql>")
    print("  python3 client.py mutate <port> <table_id> <pk> <col_idx> <type> <val>")
    print("  python3 client.py query <port> <table_id> <pk>")
    print("\nMutation Types:")
    print("  lww         - Last-Write-Wins Register (sets string value)")
    print("  pn          - Positive-Negative Counter (adds integer increment)")
    print("  set-add     - Add-Wins Set (adds element to set)")
    print("  set-remove  - Add-Wins Set (removes element from set)")
    print("\nExamples:")
    print('  python3 client.py schema 9000 10 "CREATE TABLE users { name: TEXT, karma: INT, friends: SET }"')
    print('  python3 client.py mutate 9000 10 bob1 0 lww "Bob Smith"')
    print('  python3 client.py mutate 9000 10 bob1 1 pn 100')
    print('  python3 client.py mutate 9000 10 bob1 2 set-add Alice')
    print('  python3 client.py query 9000 10 bob1')

def read_all(sock, n):
    data = b""
    while len(data) < n:
        packet = sock.recv(n - len(data))
        if not packet:
            raise EOFError("Socket closed prematurely")
        data += packet
    return data

def execute_command(port, msg_type, payload):
    header = struct.pack(HEADER_FORMAT, MAGIC, VERSION, msg_type, 0, 1, len(payload), 1)
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect(("127.0.0.1", int(port)))
        sock.sendall(header + payload)
        
        if msg_type == MSG_QUERY:
            resp_header_bytes = read_all(sock, HEADER_SIZE)
            _, _, resp_msg_type, _, _, resp_len, _ = struct.unpack(HEADER_FORMAT, resp_header_bytes)
            
            if resp_msg_type != MSG_QUERY_RESPONSE:
                print(f"Error: Expected msg_type {MSG_QUERY_RESPONSE}, got {resp_msg_type}")
                return
            
            resp_payload = read_all(sock, resp_len)
            parse_query_response(resp_payload)
            
    except Exception as e:
        print(f"Connection error: {e}")
        sys.exit(1)
    finally:
        sock.close()

def parse_query_response(payload):
    if not payload:
        print("Empty response.")
        return
        
    status = payload[0]
    if status == 0x01:
        print("Row not found.")
        return
        
    row_count = struct.unpack("<I", payload[1:5])[0]
    print(f"Query successful. Rows returned: {row_count}")
    
    pos = 5
    for r in range(row_count):
        pk_len = struct.unpack("<H", payload[pos:pos+2])[0]
        pos += 2
        pk = payload[pos:pos+pk_len].decode("utf-8", errors="replace")
        pos += pk_len
        
        cell_count = payload[pos]
        pos += 1
        print(f"Row '{pk}' has {cell_count} columns:")
        
        for c in range(cell_count):
            col_type = payload[pos]
            pos += 1
            val_len = struct.unpack("<H", payload[pos:pos+2])[0]
            pos += 2
            val_bytes = payload[pos:pos+val_len]
            pos += val_len
            
            if col_type == 2 and len(val_bytes) == 8:
                val_decoded = str(struct.unpack("<q", val_bytes)[0])
            else:
                val_decoded = val_bytes.decode("utf-8", errors="replace")
                
            print(f"  Col {c}: (type={col_type}) val='{val_decoded}'")

def main():
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(1)
        
    cmd = sys.argv[1].lower()
    
    if cmd == "schema":
        if len(sys.argv) < 5:
            print("Error: Missing arguments for schema registration.")
            print_usage()
            sys.exit(1)
        port, table_id, sql = sys.argv[2], sys.argv[3], sys.argv[4]
        payload = struct.pack("<H", int(table_id)) + sql.encode("utf-8")
        execute_command(port, MSG_ADMIN, payload)
        print(f"Schema registration sent to port {port} for Table {table_id}")
        
    elif cmd == "mutate":
        if len(sys.argv) < 8:
            print("Error: Missing arguments for mutation.")
            print_usage()
            sys.exit(1)
        port, table_id, pk, col_idx, mut_type, val = sys.argv[2:8]
        
        mut_type = mut_type.lower()
        if mut_type == "lww":
            op_code = OP_LWW_SET
            val_bytes = val.encode("utf-8")
        elif mut_type == "pn":
            op_code = OP_PN_ADD
            val_bytes = struct.pack("<q", int(val))
        elif mut_type == "set-add":
            op_code = OP_SET_ADD
            val_bytes = val.encode("utf-8")
        elif mut_type == "set-remove":
            op_code = OP_SET_REMOVE
            val_bytes = val.encode("utf-8")
        else:
            print(f"Error: Unknown mutation type '{mut_type}'")
            print_usage()
            sys.exit(1)
            
        pk_bytes = pk.encode("utf-8")
        payload = struct.pack("<HH", int(table_id), len(pk_bytes)) + pk_bytes
        payload += struct.pack("<BBB", 1, int(col_idx), op_code)
        payload += struct.pack("<H", len(val_bytes)) + val_bytes
        
        execute_command(port, MSG_MUTATION, payload)
        print(f"Mutation sent to port {port}: Table={table_id}, PK={pk}, Col={col_idx}, Op={mut_type}, Val={val}")
        
    elif cmd == "query":
        if len(sys.argv) < 5:
            print("Error: Missing arguments for query.")
            print_usage()
            sys.exit(1)
        port, table_id, pk = sys.argv[2], sys.argv[3], sys.argv[4]
        pk_bytes = pk.encode("utf-8")
        payload = struct.pack("<HH", int(table_id), len(pk_bytes)) + pk_bytes
        execute_command(port, MSG_QUERY, payload)
        
    else:
        print(f"Error: Unknown command '{cmd}'")
        print_usage()
        sys.exit(1)

if __name__ == "__main__":
    main()
