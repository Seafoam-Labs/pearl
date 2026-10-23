//! Bounded interpreter for GNU gettext plural expressions. No execution or allocation.
const std = @import("std");
const Error = error{InvalidPlural};
const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    n: u64,
    depth: usize = 0,
    fn take(self: *Parser, token: []const u8) bool {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
        if (!std.mem.startsWith(u8, self.text[self.pos..], token)) return false;
        self.pos += token.len;
        return true;
    }
    fn expression(self: *Parser, minimum: u8) Error!u64 {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 32) return error.InvalidPlural;
        var lhs: u64 = blk: {
            if (self.take("!")) break :blk @intFromBool(try self.expression(7) == 0);
            if (self.take("(")) {
                const value = try self.expression(0);
                if (!self.take(")")) return error.InvalidPlural;
                break :blk value;
            }
            if (self.take("n")) break :blk self.n;
            _ = self.take("");
            const start = self.pos;
            while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
            break :blk std.fmt.parseInt(u64, self.text[start..self.pos], 10) catch return error.InvalidPlural;
        };
        while (true) {
            const operators = [_][]const u8{ "||", "&&", "==", "!=", "<=", ">=", "<", ">", "+", "-", "*", "/", "%" };
            const precedence = [_]u8{ 1, 2, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6 };
            var matched = false;
            for (operators, precedence, 0..) |op, prec, i| {
                if (prec < minimum or !self.take(op)) continue;
                const rhs = try self.expression(prec + 1);
                lhs = switch (i) {
                    0 => @intFromBool(lhs != 0 or rhs != 0),
                    1 => @intFromBool(lhs != 0 and rhs != 0),
                    2 => @intFromBool(lhs == rhs),
                    3 => @intFromBool(lhs != rhs),
                    4 => @intFromBool(lhs <= rhs),
                    5 => @intFromBool(lhs >= rhs),
                    6 => @intFromBool(lhs < rhs),
                    7 => @intFromBool(lhs > rhs),
                    8 => lhs +% rhs,
                    9 => lhs -% rhs,
                    10 => lhs *% rhs,
                    11 => if (rhs == 0) 0 else lhs / rhs,
                    12 => if (rhs == 0) 0 else lhs % rhs,
                    else => unreachable,
                };
                matched = true;
                break;
            }
            if (!matched) break;
        }
        if (minimum == 0 and self.take("?")) {
            const yes = try self.expression(0);
            if (!self.take(":")) return error.InvalidPlural;
            const no = try self.expression(0);
            lhs = if (lhs != 0) yes else no;
        }
        return lhs;
    }
};
pub fn evaluate(expression: []const u8, n: u64) Error!u64 {
    if (expression.len == 0 or expression.len > 1024) return error.InvalidPlural;
    var p = Parser{ .text = expression, .n = n };
    const value = try p.expression(0);
    _ = p.take("");
    if (p.pos != expression.len) return error.InvalidPlural;
    return value;
}
test "German Russian Arabic plurals and malformed expressions" {
    try std.testing.expectEqual(@as(u64, 1), try evaluate("n != 1", 0));
    try std.testing.expectEqual(@as(u64, 0), try evaluate("n != 1", 1));
    const ru = "n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2";
    for ([_]u64{ 1, 2, 5, 11, 21 }, [_]u64{ 0, 1, 2, 2, 0 }) |n, expected| try std.testing.expectEqual(expected, try evaluate(ru, n));
    const ar = "n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5";
    for ([_]u64{ 0, 1, 2, 4, 15, 100 }, 0..) |n, i| try std.testing.expectEqual(@as(u64, i), try evaluate(ar, n));
    try std.testing.expectError(error.InvalidPlural, evaluate("n ? 1", 1));
    try std.testing.expectError(error.InvalidPlural, evaluate("system(1)", 1));
}
