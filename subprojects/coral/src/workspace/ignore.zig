//! Bounded Git-style ignore rules, without Git, subprocesses or filesystem I/O.
//! Paths/patterns are case-sensitive native bytes (as in Git, ? consumes one byte).
//! Caller checks every ancestor directory before loading its nested rules: a
//! negated child cannot reinclude a pruned parent. Later rules win; scopes are
//! appended root-first. Explicit excludes are separately root-anchored and final.
const std = @import("std");
pub const limits = struct {
    pub const file_bytes = 64 * 1024;
    pub const total_bytes = 256 * 1024;
    pub const rules = 2048;
    pub const pattern_bytes = 1024;
    pub const depth = 128;
    pub const excludes = 128;
    pub const match_steps = 8 * 1024 * 1024;
    pub const page_match_steps = 8 * 1024 * 1024;
    // Shared across BOTH ancestor-policy walks of one scanPage, not per ancestor.
    pub const policy_match_steps = 8 * 1024 * 1024;
    pub const policy_read_bytes = 2 * total_bytes;
    pub const policy_files = 2 * (depth + 1);
    pub const cancel_steps = 4096;
};
pub const Error = error{ IgnoreTooLarge, InvalidIgnore, OutOfMemory, MatchBudgetExceeded, PageBudgetExceeded, PolicyBudgetExceeded, Cancelled };

/// Keeps the pure matcher independent of GLib. Called synchronously, never owned.
pub const Cancellation = struct {
    context: *anyopaque,
    is_cancelled: *const fn (*anyopaque) bool,
    pub fn check(self: Cancellation) Error!void {
        if (self.is_cancelled(self.context)) return error.Cancelled;
    }
};

/// Charge BEFORE work: pattern bytes per NFA row (including the terminal row),
/// plus path/scope bytes per rule. The aggregate counter is never reset by a
/// filename, pattern, exclude pass or ignore pass. beginPath resets ONLY the
/// independent per-path cap, shared by excludes and ignores for that path.
pub const Budget = struct {
    remaining: usize = limits.match_steps,
    single_remaining: usize = limits.match_steps,
    kind: enum { single, page, policy } = .single,
    cancellation: ?Cancellation = null,
    until_poll: usize = 0,

    pub fn beginPath(self: *Budget) Error!void {
        self.single_remaining = limits.match_steps;
        if (self.cancellation) |cancel| try cancel.check();
    }

    pub fn charge(self: *Budget, amount: usize) Error!void {
        // Chunk even long path/scope charges, so cancellation is checked at most
        // every 4096 charged steps. NFA rows are <=1024 bytes, no recursive work.
        var left = amount;
        while (left > 0) {
            if (self.until_poll == 0) {
                if (self.cancellation) |cancel| try cancel.check();
                self.until_poll = limits.cancel_steps;
            }
            const n = @min(left, self.until_poll);
            if (n > self.single_remaining) return error.MatchBudgetExceeded;
            if (n > self.remaining) return switch (self.kind) {
                .single => error.MatchBudgetExceeded,
                .page => error.PageBudgetExceeded,
                .policy => error.PolicyBudgetExceeded,
            };
            self.remaining -= n;
            self.single_remaining -= n;
            self.until_poll -= n;
            left -= n;
        }
    }
};
pub const Rule = struct {
    pattern: []const u8,
    base: []const u8,
    negate: bool,
    anchored: bool,
    directory_only: bool,
};
pub const Rules = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Rule) = .empty,
    bytes: usize = 0,

    pub fn deinit(self: *Rules) void {
        for (self.items.items) |rule| {
            self.allocator.free(rule.pattern);
            self.allocator.free(rule.base);
        }
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *Rules, base: []const u8, input: []const u8) Error!void {
        return self.appendCancellable(base, input, null);
    }

    pub fn appendCancellable(self: *Rules, base: []const u8, input: []const u8, cancellation: ?Cancellation) Error!void {
        if (cancellation) |cancel| try cancel.check();
        if (input.len > limits.file_bytes or input.len > limits.total_bytes - self.bytes) return error.IgnoreTooLarge;
        self.bytes += input.len;
        if (std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidIgnore;
        var lines = std.mem.splitScalar(u8, input, '\n');
        var first = true;
        while (lines.next()) |raw| {
            // One line is bounded by file_bytes, including comments/whitespace.
            if (cancellation) |cancel| try cancel.check();
            var line = raw;
            if (first and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
            first = false;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            // Only unescaped trailing spaces are discarded; retain the escape
            // itself so the matcher distinguishes a literal space or metachar.
            while (line.len > 0 and line[line.len - 1] == ' ') {
                var slashes: usize = 0;
                var i = line.len - 1;
                while (i > 0 and line[i - 1] == '\\') : (i -= 1) slashes += 1;
                if (slashes % 2 == 1) break;
                line = line[0 .. line.len - 1];
            }
            if (line.len == 0 or line[0] == '#') continue;
            if (line.len > limits.pattern_bytes) return error.IgnoreTooLarge;
            const negate = line[0] == '!';
            if (negate) line = line[1..];
            if (line.len == 0) continue;
            const directory_only = line[line.len - 1] == '/';
            if (directory_only) line = line[0 .. line.len - 1];
            const anchored = std.mem.indexOfScalar(u8, line, '/') != null;
            if (line.len > 0 and line[0] == '/') line = line[1..];
            if (line.len == 0) continue;
            if (self.items.items.len == limits.rules) return error.IgnoreTooLarge;
            // Scope strings count against the storage cap too (deep trees cannot
            // multiply a small ignore file into unbounded rule allocations).
            if (base.len > limits.total_bytes - self.bytes) return error.IgnoreTooLarge;
            self.bytes += base.len;
            const pattern = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(pattern);
            const owned_base = try self.allocator.dupe(u8, base);
            errdefer self.allocator.free(owned_base);
            try self.items.append(self.allocator, .{ .pattern = pattern, .base = owned_base, .negate = negate, .anchored = anchored, .directory_only = directory_only });
        }
    }

    /// Exact path only. Parent pruning is the filesystem walker's responsibility.
    pub fn ignored(self: *const Rules, path: []const u8, directory: bool) Error!bool {
        var budget = Budget{};
        return self.ignoredBudget(path, directory, &budget);
    }

    pub fn ignoredBudget(self: *const Rules, path: []const u8, directory: bool, budget: *Budget) Error!bool {
        // Last matching rule wins, including negation and deeper scopes. Reverse
        // evaluation is equivalent to a full forward pass, but duplicate rules
        // cannot multiply the cost of an already determined answer.
        var index = self.items.items.len;
        while (index > 0) {
            index -= 1;
            const rule = self.items.items[index];
            try budget.charge(1 + path.len + rule.base.len);
            if (rule.directory_only and !directory) continue;
            var local = path;
            if (rule.base.len > 0) {
                if (path.len <= rule.base.len or !std.mem.startsWith(u8, path, rule.base) or path[rule.base.len] != '/') continue;
                local = path[rule.base.len + 1 ..];
            }
            if (!rule.anchored) local = std.fs.path.basename(local);
            if (try matchBudget(rule.pattern, local, budget)) return !rule.negate;
        }
        return false;
    }
};

/// Explicit excludes are NOT ignore-file lines: no comments, negation or space
/// trimming. Leading slash is optional, all patterns are root-relative. `**/x`
/// matches x at any depth; `x` matches only root x. Directory matches prune.
pub fn validateExclude(pattern: []const u8) error{InvalidSchema}!void {
    if (pattern.len == 0 or pattern.len > limits.pattern_bytes or pattern[0] == '!' or std.mem.indexOfScalar(u8, pattern, 0) != null or std.mem.indexOfScalar(u8, pattern, '\n') != null or std.mem.indexOfScalar(u8, pattern, '\r') != null) return error.InvalidSchema;
    var p = pattern;
    if (p[0] == '/') p = p[1..];
    if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return error.InvalidSchema;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidSchema;
    }
}

pub fn excluded(patterns: []const []const u8, path: []const u8, directory: bool) Error!bool {
    var budget = Budget{};
    return excludedBudget(patterns, path, directory, &budget);
}

pub fn excludedBudget(patterns: []const []const u8, path: []const u8, directory: bool, budget: *Budget) Error!bool {
    for (patterns) |original| {
        try budget.charge(1 + path.len);
        var pattern = original;
        if (pattern[0] == '/') pattern = pattern[1..];
        if (pattern[pattern.len - 1] == '/') {
            if (!directory) continue;
            pattern = pattern[0 .. pattern.len - 1];
        }
        if (try matchBudget(pattern, path, budget)) return true;
    }
    return false;
}

pub fn match(pattern: []const u8, path: []const u8) Error!bool {
    var budget = Budget{};
    return matchBudget(pattern, path, &budget);
}

// Thompson-style state simulation: two fixed bitsets, no recursive wildcard
// backtracking and no allocation. O(pattern bytes * path bytes), with a budget.
pub fn matchBudget(pattern: []const u8, path: []const u8, budget: *Budget) Error!bool {
    if (pattern.len > limits.pattern_bytes) return error.IgnoreTooLarge;
    const Bits = std.StaticBitSet(limits.pattern_bytes + 1);
    var current = Bits.empty;
    current.set(0);
    var next = Bits.empty;
    var middle = Bits.empty;
    var next_middle = Bits.empty;
    for (0..path.len + 1) |at| {
        try budget.charge(pattern.len);
        next = Bits.empty;
        next_middle = Bits.empty;
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            const active = current.isSet(i);
            const ch = if (at < path.len) path[at] else 0;
            switch (pattern[i]) {
                '*' => {
                    var end = i + 1;
                    while (end < pattern.len and pattern[end] == '*') : (end += 1) {}
                    const globstar = end - i >= 2 and (i == 0 or pattern[i - 1] == '/') and (end == pattern.len or pattern[end] == '/');
                    if (globstar and end < pattern.len) {
                        // **/ has a zero-component transition; after consuming
                        // bytes it can leave only at a slash boundary.
                        if (active) current.set(end + 1);
                        if (at < path.len and (active or middle.isSet(i))) {
                            // A separate state remembers consumed bytes so **/x
                            // cannot match a suffix within an ordinary component.
                            next_middle.set(i);
                            if (ch == '/') next.set(end + 1);
                        }
                    } else {
                        if (active) current.set(end);
                        if (active and at < path.len and (globstar or ch != '/')) next.set(i);
                    }
                    i = if (globstar and end < pattern.len) end else end - 1;
                },
                '?' => if (active and at < path.len and ch != '/') {
                    next.set(i + 1);
                },
                '\\' => {
                    if (i + 1 < pattern.len) {
                        if (active and at < path.len and ch == pattern[i + 1]) next.set(i + 2);
                        i += 1;
                    }
                },
                '[' => {
                    const cls = bracket(pattern[i..], ch);
                    if (cls) |value| {
                        if (active and at < path.len and ch != '/' and value.matches) next.set(i + value.len);
                        i += value.len - 1;
                    } else return false; // Git wildmatch rejects malformed brackets.
                },
                else => if (active and at < path.len and ch == pattern[i]) {
                    next.set(i + 1);
                },
            }
        }
        if (at == path.len) return current.isSet(pattern.len);
        current = next;
        middle = next_middle;
        if (current.count() == 0 and middle.count() == 0) return false;
    }
    unreachable;
}

const Class = struct { len: usize, matches: bool };
fn bracket(p: []const u8, ch: u8) ?Class {
    var i: usize = 1;
    const negated = i < p.len and (p[i] == '!' or p[i] == '^');
    if (negated) i += 1;
    var hit = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ .len = i + 1, .matches = hit != negated };
        first = false;
        if (p[i] == '[' and i + 1 < p.len and p[i + 1] == ':') {
            const end = std.mem.indexOfPos(u8, p, i + 2, ":]") orelse return null;
            const matched = namedClass(p[i + 2 .. end], ch) orelse return null;
            hit = hit or matched;
            i = end + 2;
            continue;
        }
        if (p[i] == '\\' and i + 1 < p.len) i += 1;
        const low = p[i];
        i += 1;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            i += 1;
            if (p[i] == '\\' and i + 1 < p.len) i += 1;
            hit = hit or (ch >= low and ch <= p[i]);
            i += 1;
        } else hit = hit or ch == low;
    }
    return null;
}

fn namedClass(name: []const u8, ch: u8) ?bool {
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(ch);
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(ch);
    if (std.mem.eql(u8, name, "blank")) return ch == ' ' or ch == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return std.ascii.isControl(ch);
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(ch);
    if (std.mem.eql(u8, name, "graph")) return ch >= 33 and ch <= 126;
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(ch);
    if (std.mem.eql(u8, name, "print")) return ch >= 32 and ch <= 126;
    if (std.mem.eql(u8, name, "punct")) return ch >= 33 and ch <= 126 and !std.ascii.isAlphanumeric(ch);
    if (std.mem.eql(u8, name, "space")) return std.ascii.isWhitespace(ch);
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(ch);
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(ch);
    return null;
}

test {
    _ = @import("ignore_test.zig");
}
