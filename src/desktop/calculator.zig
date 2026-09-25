//! Bounded, allocation-free real arithmetic. No locale or executable input.
const std = @import("std");
pub const input_limit = 512;
const token_limit = 256;
const depth_limit = 32;
const operation_limit = 256;
pub const Failure = error{ Incomplete, Syntax, UnknownFunction, NumberFormat, DivisionByZero, Domain, Overflow, Limit };
pub const Diagnostic = struct { kind: Failure, position: usize };
pub const Value = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    pub fn text(self: *const Value) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Outcome = union(enum) { not_applicable, incomplete, value: Value, diagnostic: Diagnostic };
pub const Evaluation = struct {
    explicit: bool = false,
    continuation: bool = false,
    outcome: Outcome = .not_applicable,
};

pub fn evaluate(input: []const u8) Evaluation {
    var query = std.mem.trim(u8, input, " \t\r\n");
    var result: Evaluation = .{ .explicit = std.mem.startsWith(u8, query, "=") };
    if (input.len > input_limit) {
        result.outcome = .{ .diagnostic = .{ .kind = error.Limit, .position = input_limit } };
        return result;
    }
    if (result.explicit) query = std.mem.trimStart(u8, query[1..], " \t\r\n");
    if (query.len > 0 and query[query.len - 1] == '=') {
        result.continuation = true;
        query = query[0 .. query.len - 1];
    }
    if (!result.explicit) {
        if (query.len == 0 or std.mem.indexOfScalar(u8, "0123456789.(+-", query[0]) == null) return result;
        for (query) |c| if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, ".eE+-*/^() \t\r\n", c) == null) return result;
    }
    var parser: Parser = .{ .input = query, .advanced = result.explicit };
    const number = parser.run() catch |err| {
        if (!result.explicit and !parser.binary) return result;
        result.outcome = if (err == error.Incomplete) .incomplete else .{ .diagnostic = .{ .kind = err, .position = @intFromPtr(query.ptr) - @intFromPtr(input.ptr) + parser.position } };
        return result;
    };
    if (!result.explicit and !parser.binary) return result;
    result.outcome = .{ .value = format(number) };
    return result;
}

const Token = union(enum) { end, number: f64, name: []const u8, symbol: u8 };
const Parser = struct {
    input: []const u8,
    advanced: bool,
    position: usize = 0,
    cursor: usize = 0,
    tokens: usize = 0,
    operations: usize = 0,
    binary: bool = false,
    token: Token = .end,

    fn next(self: *Parser) Failure!void {
        while (self.cursor < self.input.len and std.ascii.isWhitespace(self.input[self.cursor])) self.cursor += 1;
        self.position = self.cursor;
        if (self.cursor == self.input.len) {
            self.token = .end;
            return;
        }
        self.tokens += 1;
        if (self.tokens > token_limit) return error.Limit;
        const start = self.cursor;
        const c = self.input[self.cursor];
        self.cursor += 1;
        if (std.ascii.isDigit(c) or c == '.') {
            while (self.cursor < self.input.len and (std.ascii.isDigit(self.input[self.cursor]) or self.input[self.cursor] == '.')) self.cursor += 1;
            if (self.cursor < self.input.len and (self.input[self.cursor] == 'e' or self.input[self.cursor] == 'E')) {
                self.cursor += 1;
                if (self.cursor < self.input.len and (self.input[self.cursor] == '+' or self.input[self.cursor] == '-')) self.cursor += 1;
                if (self.cursor == self.input.len) return error.Incomplete;
                while (self.cursor < self.input.len and std.ascii.isDigit(self.input[self.cursor])) self.cursor += 1;
            }
            const value = std.fmt.parseFloat(f64, self.input[start..self.cursor]) catch return error.Syntax;
            if (!std.math.isFinite(value)) return error.Overflow;
            self.token = .{ .number = value };
        } else if (std.ascii.isAlphabetic(c)) {
            while (self.cursor < self.input.len and std.ascii.isAlphanumeric(self.input[self.cursor])) self.cursor += 1;
            if (!self.advanced) return error.Syntax;
            self.token = .{ .name = self.input[start..self.cursor] };
        } else if (std.mem.indexOfScalar(u8, "+-*/^(),", c) != null) {
            self.token = .{ .symbol = c };
        } else return if (c == '$' or c >= 128) error.NumberFormat else error.Syntax;
    }
    fn is(self: *const Parser, c: u8) bool {
        return self.token == .symbol and self.token.symbol == c;
    }
    fn require(self: *Parser, c: u8) Failure!void {
        if (self.token == .end) return error.Incomplete;
        if (!self.is(c)) return error.Syntax;
        try self.next();
    }
    fn checked(self: *Parser, value: f64) Failure!f64 {
        self.operations += 1;
        if (self.operations > operation_limit) return error.Limit;
        if (std.math.isNan(value)) return error.Domain;
        if (!std.math.isFinite(value)) return error.Overflow;
        return value;
    }
    fn run(self: *Parser) Failure!f64 {
        try self.next();
        const value = try self.expression(0, 0);
        if (self.is(',')) return error.NumberFormat;
        if (self.token != .end) return error.Syntax;
        return value;
    }
    fn expression(self: *Parser, minimum: u8, depth: usize) Failure!f64 {
        if (depth >= depth_limit) return error.Limit;
        var left: f64 = switch (self.token) {
            .end => return error.Incomplete,
            .number => |v| blk: {
                try self.next();
                break :blk v;
            },
            .symbol => |c| blk: {
                if (c == '+' or c == '-') {
                    try self.next();
                    const v = try self.expression(3, depth + 1);
                    break :blk try self.checked(if (c == '-') -v else v);
                }
                if (c != '(') return error.Syntax;
                try self.next();
                const v = try self.expression(0, depth + 1);
                try self.require(')');
                break :blk v;
            },
            .name => |name| blk: {
                try self.next();
                if (std.ascii.eqlIgnoreCase(name, "pi")) break :blk std.math.pi;
                if (std.ascii.eqlIgnoreCase(name, "e")) break :blk std.math.e;
                const function = Function.from(name) orelse return error.UnknownFunction;
                try self.require('(');
                const first = try self.expression(0, depth + 1);
                var second: f64 = 0;
                if (function == .mod) {
                    try self.require(',');
                    second = try self.expression(0, depth + 1);
                }
                try self.require(')');
                break :blk try self.checked(try function.call(first, second));
            },
        };
        while (self.token == .symbol) {
            const op = self.token.symbol;
            const precedence: u8 = switch (op) {
                '+', '-' => 1,
                '*', '/' => 2,
                '^' => 4,
                else => break,
            };
            if (precedence < minimum) break;
            self.binary = true;
            try self.next();
            const right = try self.expression(if (op == '^') precedence else precedence + 1, depth + 1);
            left = try self.checked(switch (op) {
                '+' => left + right,
                '-' => left - right,
                '*' => left * right,
                '/' => if (right == 0) return error.DivisionByZero else left / right,
                '^' => if (left == 0 and right < 0) return error.DivisionByZero else if (left < 0 and @trunc(right) != right) return error.Domain else std.math.pow(f64, left, right),
                else => unreachable,
            });
        }
        return left;
    }
};
const Function = enum {
    abs,
    sqrt,
    exp,
    ln,
    log,
    log2,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    ceil,
    floor,
    round,
    trunc,
    mod,
    fn from(name: []const u8) ?Function {
        inline for (std.meta.fields(Function)) |field| if (std.ascii.eqlIgnoreCase(name, field.name)) return @enumFromInt(field.value);
        return null;
    }
    fn call(self: Function, x: f64, y: f64) Failure!f64 {
        return switch (self) {
            .abs => @abs(x),
            .sqrt => if (x < 0) error.Domain else @sqrt(x),
            .exp => @exp(x),
            .ln => if (x <= 0) error.Domain else @log(x),
            .log => if (x <= 0) error.Domain else @log10(x),
            .log2 => if (x <= 0) error.Domain else @log2(x),
            .sin => @sin(x),
            .cos => @cos(x),
            .tan => std.math.tan(x),
            .asin => if (@abs(x) > 1) error.Domain else std.math.asin(x),
            .acos => if (@abs(x) > 1) error.Domain else std.math.acos(x),
            .atan => std.math.atan(x),
            .ceil => @ceil(x),
            .floor => @floor(x),
            .round => @round(x),
            .trunc => @trunc(x),
            .mod => if (y == 0) error.DivisionByZero else @rem(x, y),
        };
    }
};

// Round once to 15 significant digits, then lay out the decimal ourselves so
// display, copy and continuation share the same locale-independent value.
fn format(number: f64) Value {
    var result: Value = .{};
    if (number == 0) {
        result.bytes[0] = '0';
        result.len = 1;
        return result;
    }
    var scientific: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&scientific, "{e:.14}", .{@abs(number)}) catch unreachable;
    const e = std.mem.indexOfScalar(u8, text, 'e').?;
    // Rounding the largest finite f64 upward to 15 digits would produce an
    // unparseable infinity. Round that one boundary down by one decimal ULP.
    if (!std.math.isFinite(std.fmt.parseFloat(f64, text) catch unreachable)) {
        var digit = e;
        while (digit > 0) {
            digit -= 1;
            if (text[digit] == '.') continue;
            if (text[digit] > '0') {
                text[digit] -= 1;
                break;
            }
            text[digit] = '9';
        }
    }
    const exponent = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch unreachable;
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (text[0..e]) |c| if (c != '.') {
        digits[n] = c;
        n += 1;
    };
    while (n > 1 and digits[n - 1] == '0') n -= 1;
    if (number < 0) {
        result.bytes[0] = '-';
        result.len = 1;
    }
    if (exponent < -6 or exponent >= 15) {
        result.bytes[result.len] = digits[0];
        result.len += 1;
        if (n > 1) {
            result.bytes[result.len] = '.';
            result.len += 1;
            @memcpy(result.bytes[result.len..][0 .. n - 1], digits[1..n]);
            result.len += n - 1;
        }
        const tail = std.fmt.bufPrint(result.bytes[result.len..], "e{d}", .{exponent}) catch unreachable;
        result.len += tail.len;
    } else {
        const point = exponent + 1;
        var i: i32 = @min(0, point);
        if (point <= 0) {
            result.bytes[result.len] = '0';
            result.len += 1;
        }
        while (i < @max(point, @as(i32, @intCast(n)))) : (i += 1) {
            if (i == point) {
                result.bytes[result.len] = '.';
                result.len += 1;
            }
            result.bytes[result.len] = if (i >= 0 and i < n) digits[@intCast(i)] else '0';
            result.len += 1;
        }
    }
    return result;
}

fn expectValue(query: []const u8, expected: []const u8) !void {
    const result = evaluate(query);
    try std.testing.expect(result.outcome == .value);
    try std.testing.expectEqualStrings(expected, result.outcome.value.text());
    var continued: [130]u8 = undefined;
    const requery = try std.fmt.bufPrint(&continued, "={s}", .{result.outcome.value.text()});
    const reparsed = evaluate(requery);
    try std.testing.expect(reparsed.outcome == .value);
    try std.testing.expectEqualStrings(expected, reparsed.outcome.value.text());
}
test "arithmetic precedence, signs, notation and formatting round trips" {
    const cases = [_][2][]const u8{
        .{ "12*(3+4)", "84" },                           .{ "2^3^2", "512" },      .{ "-2^2", "-4" },               .{ "2^-2", "0.25" },
        .{ "1e3+2e-3", "1000.002" },                     .{ ".5 + .25", "0.75" },  .{ "1/3", "0.333333333333333" }, .{ "0.1+0.2", "0.3" },
        .{ "=-0", "0" },                                 .{ "=1e-6", "0.000001" }, .{ "=1e-7", "1e-7" },            .{ "=1e15", "1e15" },
        .{ "=1e14", "100000000000000" },                 .{ "=1e308", "1e308" },   .{ "=1e-320", "1e-320" },        .{ "=1e-400", "0" },
        .{ "=9007199254740993", "9.00719925474099e15" }, .{ "12*7=", "84" },       .{ "=42", "42" },                .{ "=-.123", "-0.123" },
        .{ "=999999999999999.9", "1e15" },
    };
    for (cases) |case| try expectValue(case[0], case[1]);
}
test "every advanced function and constants" {
    const cases = [_][2][]const u8{
        .{ "=ABS(-2)", "2" },        .{ "=sqrt(81)=", "9" },    .{ "=exp(0)", "1" },       .{ "=ln(e)", "1" },
        .{ "=log(100)", "2" },       .{ "=log2(8)", "3" },      .{ "=sin(0)", "0" },       .{ "=cos(0)", "1" },
        .{ "=tan(0)", "0" },         .{ "=asin(0)", "0" },      .{ "=acos(1)", "0" },      .{ "=atan(0)", "0" },
        .{ "=ceil(-1.2)", "-1" },    .{ "=floor(-1.2)", "-2" }, .{ "=round(-1.5)", "-2" }, .{ "=round(1.5)", "2" },
        .{ "=trunc(-1.9)", "-1" },   .{ "=mod(-7,3)", "-1" },   .{ "=mod(7,-3)", "1" },    .{ "=cos(pi)", "-1" },
        .{ "=sqrt(abs(-81))", "9" },
    };
    for (cases) |case| try expectValue(case[0], case[1]);
}
test "classification, incomplete expressions and diagnostics" {
    for ([_][]const u8{ "", "42", "-42", "Firefox", "1password", "org.app", "/tmp/file", "sqrt(9)", "1+hello", "foo=", "1e-3" }) |query| try std.testing.expect(evaluate(query).outcome == .not_applicable);
    for ([_][]const u8{ "=", "2+", "=sqrt(", "=(2", "=1e-", "=mod(2," }) |query| try std.testing.expect(evaluate(query).outcome == .incomplete);
    const cases = [_]struct { []const u8, Failure }{
        .{ "=1/0", error.DivisionByZero }, .{ "=sqrt(-1)", error.Domain },            .{ "=ln(0)", error.Domain },
        .{ "=log(-1)", error.Domain },     .{ "=log2(0)", error.Domain },             .{ "=asin(2)", error.Domain },
        .{ "=acos(-2)", error.Domain },    .{ "=mod(1,0)", error.DivisionByZero },    .{ "=0^-1", error.DivisionByZero },
        .{ "=(-1)^0.5", error.Domain },    .{ "=1e309", error.Overflow },             .{ "=exp(1000)", error.Overflow },
        .{ "=1e308*2", error.Overflow },   .{ "=unknown(2)", error.UnknownFunction }, .{ "=2(3)", error.Syntax },
        .{ "=1,234", error.NumberFormat }, .{ "=$2", error.NumberFormat },            .{ "=20%", error.Syntax },
        .{ "=1..2", error.Syntax },        .{ "=1+2junk", error.Syntax },             .{ "=sqrt(1,2)", error.Syntax },
    };
    for (cases) |case| {
        const result = evaluate(case[0]);
        try std.testing.expect(result.outcome == .diagnostic);
        try std.testing.expectEqual(case[1], result.outcome.diagnostic.kind);
        try std.testing.expect(result.outcome.diagnostic.position <= case[0].len);
    }
    try std.testing.expect(evaluate("2+3=").continuation);
    try std.testing.expect(evaluate("=2+3").explicit);
}
test "resource limits and seeded malformed input never panic" {
    const too_long = [_]u8{'1'} ** 513;
    try std.testing.expectEqual(error.Limit, evaluate(&too_long).outcome.diagnostic.kind);
    for ([_][]const u8{ "=" ++ "(" ** 32 ++ "1" ++ ")" ** 32, "=" ++ "-" ** 32 ++ "1", "=" ++ "2^" ** 32 ++ "1", "=" ++ "1+" ** 128 ++ "1" }) |query| {
        try std.testing.expectEqual(error.Limit, evaluate(query).outcome.diagnostic.kind);
    }
    var parser: Parser = .{ .input = "1+2", .advanced = true, .operations = operation_limit };
    try std.testing.expectError(error.Limit, parser.run());
    var random = std.Random.DefaultPrng.init(0xCA1C);
    var bytes: [512]u8 = undefined;
    const alphabet = "0123456789.eE+-*/^(),= abcdef\x00\xff";
    for (0..10000) |_| {
        const len = random.random().uintLessThan(usize, bytes.len) + 1;
        bytes[0] = '=';
        for (bytes[1..len]) |*c| c.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        const result = evaluate(bytes[0..len]);
        if (result.outcome == .value) try std.testing.expect(result.outcome.value.len < 128);
    }
}

test "finite numeric boundaries remain finite and stable after display rounding" {
    try expectValue("=1.7976931348623157e308", "1.79769313486231e308");
    try expectValue("=-1.7976931348623157e308", "-1.79769313486231e308");
    try expectValue("=5e-324", "5e-324");
    var random = std.Random.DefaultPrng.init(0xF64);
    for (0..10000) |_| {
        const number: f64 = @bitCast(random.next());
        if (!std.math.isFinite(number)) continue;
        const value = format(number);
        const reparsed = try std.fmt.parseFloat(f64, value.text());
        try std.testing.expect(std.math.isFinite(reparsed));
        const second = format(reparsed);
        try std.testing.expectEqualStrings(value.text(), second.text());
    }
}
