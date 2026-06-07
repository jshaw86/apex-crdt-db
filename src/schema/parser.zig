const std = @import("std");
const engine = @import("../storage/engine.zig");
const schema_mod = @import("engine.zig");

pub const Token = enum {
    keyword_create,
    keyword_table,
    keyword_text,
    keyword_int,
    keyword_set,
    identifier,
    left_brace,
    right_brace,
    colon,
    comma,
    eof,
    invalid,
};

pub const TokenResult = struct {
    token: Token,
    slice: []const u8,
};

pub const Lexer = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn init(buffer: []const u8) Lexer {
        return .{ .buffer = buffer };
    }

    pub fn next(self: *Lexer) TokenResult {
        self.skipWhitespace();
        if (self.pos >= self.buffer.len) return .{ .token = .eof, .slice = "" };

        const start = self.pos;
        const c = self.buffer[self.pos];

        switch (c) {
            '{' => { self.pos += 1; return .{ .token = .left_brace, .slice = "{" }; },
            '}' => { self.pos += 1; return .{ .token = .right_brace, .slice = "}" }; },
            ':' => { self.pos += 1; return .{ .token = .colon, .slice = ":" }; },
            ',' => { self.pos += 1; return .{ .token = .comma, .slice = "," }; },
            else => {},
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.buffer.len and (std.ascii.isAlphanumeric(self.buffer[self.pos]) or self.buffer[self.pos] == '_')) {
                self.pos += 1;
            }
            const slice = self.buffer[start..self.pos];
            
            // Check Keywords (Case-Insensitive)
            if (std.ascii.eqlIgnoreCase(slice, "CREATE")) return .{ .token = .keyword_create, .slice = slice };
            if (std.ascii.eqlIgnoreCase(slice, "TABLE")) return .{ .token = .keyword_table, .slice = slice };
            if (std.ascii.eqlIgnoreCase(slice, "TEXT")) return .{ .token = .keyword_text, .slice = slice };
            if (std.ascii.eqlIgnoreCase(slice, "INT")) return .{ .token = .keyword_int, .slice = slice };
            if (std.ascii.eqlIgnoreCase(slice, "SET")) return .{ .token = .keyword_set, .slice = slice };
            
            return .{ .token = .identifier, .slice = slice };
        }

        self.pos += 1;
        return .{ .token = .invalid, .slice = self.buffer[start..self.pos] };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.buffer.len and std.ascii.isWhitespace(self.buffer[self.pos])) {
            self.pos += 1;
        }
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator, .lexer = undefined };
    }

    pub fn parse(self: *Parser, id: u16, input: []const u8) !*schema_mod.TableSchema {
        self.lexer = Lexer.init(input);

        // Expect "CREATE"
        if ((try self.expect(.keyword_create)).token != .keyword_create) return error.ExpectedCreate;
        // Expect "TABLE"
        _ = try self.expect(.keyword_table);
        
        // Expect Table Name
        const name_tok = try self.expect(.identifier);
        const schema = try self.allocator.create(schema_mod.TableSchema);
        const name_copy = try self.allocator.dupe(u8, name_tok.slice);
        schema.* = schema_mod.TableSchema.init(self.allocator, id, name_copy);
        errdefer schema.deinit(self.allocator);

        // Expect "{"
        _ = try self.expect(.left_brace);

        while (true) {
            const tok = self.lexer.next();
            if (tok.token == .right_brace) break;
            if (tok.token == .eof) return error.UnclosedBrace;

            if (tok.token != .identifier) return error.ExpectedColumnName;
            const col_name = tok.slice;

            _ = try self.expect(.colon);
            
            const type_tok = self.lexer.next();
            const crdt_type: engine.CrdtType = switch (type_tok.token) {
                .keyword_text => .lww_register,
                .keyword_int => .pn_counter,
                .keyword_set => .aw_set,
                else => return error.UnknownType,
            };

            try schema.addColumn(self.allocator, col_name, crdt_type);

            // Handle optional comma
            const next_tok = self.lexer.next();
            if (next_tok.token == .right_brace) break;
            if (next_tok.token != .comma) {
                // Rewind if it wasn't a comma
                self.lexer.pos -= next_tok.slice.len;
            }
        }

        return schema;
    }

    fn expect(self: *Parser, expected: Token) !TokenResult {
        const tok = self.lexer.next();
        if (tok.token != expected) {
            std.debug.print("Expected {s}, got {s} ('{s}')\n", .{ @tagName(expected), @tagName(tok.token), tok.slice });
            return error.UnexpectedToken;
        }
        return tok;
    }
};
