//! Whether Pearl has systemd's signals for scx.service, and when to connect
//! to systemd again. The unit's state changes reach Pearl only as signals on
//! proxies subscribed to systemd's current bus name: when the proxies could
//! not be made, the subscription failed, or systemd left the bus or came
//! back under another name (re-executed or restarted), the signals are gone
//! and Pearl polls scxcli until a connection to the current owner is whole.
//! Pure state; the service makes the proxies.
const std = @import("std");

const Name = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn set(self: *Name, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }

    fn get(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Link = struct {
    /// systemd's unique bus name as last seen; empty while it is not on the
    /// bus, or before the bus said.
    owner: Name = .{},
    /// The owner the current attempt was made against; empty when it was
    /// made before the bus said who owns the name.
    target: Name = .{},
    /// Counts attempts, so a result from a superseded one is discarded.
    attempt: u32 = 0,
    /// The unit's proxy, the unit's Service proxy (how its runs end, how
    /// often systemd restarted it) and the manager's Subscribe, for the
    /// current attempt: null while pending.
    unit: ?bool = null,
    service: ?bool = null,
    subscribed: ?bool = null,
    /// An attempt is under way.
    connecting: bool = false,
    /// systemd changed owner while an attempt was under way: connect again
    /// once it is over.
    again: bool = false,

    /// Start an attempt, numbered `attempt`; false while one is under way,
    /// which then runs again when it is over.
    pub fn begin(self: *Link) bool {
        if (self.connecting) {
            self.again = true;
            return false;
        }
        self.attempt +%= 1;
        self.target = self.owner;
        self.unit = null;
        self.service = null;
        self.subscribed = null;
        self.connecting = true;
        self.again = false;
        return true;
    }

    /// The result belongs to the current attempt.
    pub fn current(self: *const Link, attempt: u32) bool {
        return attempt == self.attempt;
    }

    /// The unit's proxy was made, or could not be. Returns whether to
    /// connect again now.
    pub fn unitResult(self: *Link, attempt: u32, ok: bool) bool {
        if (!self.current(attempt)) return false;
        self.unit = ok;
        return self.settle();
    }

    /// The unit's Service proxy was made, or could not be. Returns whether
    /// to connect again now.
    pub fn serviceResult(self: *Link, attempt: u32, ok: bool) bool {
        if (!self.current(attempt)) return false;
        self.service = ok;
        return self.settle();
    }

    /// The manager's Subscribe answered, or could not be sent. Returns
    /// whether to connect again now.
    pub fn subscribeResult(self: *Link, attempt: u32, ok: bool) bool {
        if (!self.current(attempt)) return false;
        self.subscribed = ok;
        return self.settle();
    }

    fn settle(self: *Link) bool {
        const steps = [_]?bool{ self.unit, self.service, self.subscribed };
        var pending = false;
        var failed = false;
        for (steps) |step| {
            pending = pending or step == null;
            failed = failed or step == false;
        }
        // A failed step ends the attempt; the other results are not needed.
        if (pending and !failed) return false;
        self.connecting = false;
        const again = self.again;
        self.again = false;
        return again;
    }

    /// systemd took its name. Returns whether to connect now: when the
    /// connection is not whole, or was made against another owner.
    pub fn appeared(self: *Link, owner: []const u8) bool {
        const first = self.owner.len == 0 and self.target.len == 0;
        self.owner.set(owner);
        // An attempt made before the bus said who owns the name was made
        // against this owner if it is the first one seen.
        if (first and self.target.len == 0) self.target.set(owner);
        if (std.mem.eql(u8, self.target.get(), owner) and (self.connecting or self.whole())) return false;
        if (self.connecting) {
            self.again = true;
            return false;
        }
        return true;
    }

    /// systemd left the bus: its signals are gone until it comes back.
    pub fn vanished(self: *Link) void {
        self.owner.len = 0;
    }

    /// The proxies and the subscription of the last attempt all worked.
    fn whole(self: *const Link) bool {
        return self.unit == true and self.service == true and self.subscribed == true;
    }

    /// A poll should try to connect again: the last attempt did not end
    /// whole, none is under way, and systemd is on the bus (or the bus has
    /// not said).
    pub fn retry(self: *const Link) bool {
        if (self.connecting or self.whole()) return false;
        return self.owner.len > 0 or self.target.len == 0;
    }

    /// The signals cannot be relied on, so scxcli has to be asked
    /// periodically.
    pub fn polling(self: *const Link) bool {
        if (self.connecting) return true;
        if (!self.whole()) return true;
        // Connected before the bus said who owns the name; it has not said
        // anything else either.
        if (self.owner.len == 0) return self.target.len != 0;
        return !std.mem.eql(u8, self.owner.get(), self.target.get());
    }
};

const t = std.testing;

/// Connect and get every result.
fn connect(link: *Link, unit: bool, subscribe: bool) bool {
    return connectAll(link, unit, true, subscribe);
}

fn connectAll(link: *Link, unit: bool, service: bool, subscribe: bool) bool {
    if (!link.begin()) return false;
    const n = link.attempt;
    _ = link.subscribeResult(n, subscribe);
    _ = link.serviceResult(n, service);
    return link.unitResult(n, unit);
}

test "a failed Service proxy keeps polling and retrying" {
    var link: Link = .{};
    _ = link.appeared(":1.1");
    // Unit proxy and Subscribe work, the Service proxy (NRestarts) does not.
    _ = connectAll(&link, true, false, true);
    try t.expect(link.polling());
    try t.expect(link.retry());
    // The retry makes all three anew.
    _ = connectAll(&link, true, true, true);
    try t.expect(!link.polling());
}

test "a whole connection to the current owner needs no polling" {
    var link: Link = .{};
    // Pearl connects at start, before the bus has said who owns the name.
    try t.expect(!connect(&link, true, true));
    try t.expect(!link.polling());
    // The first owner seen is the one connected to.
    try t.expect(!link.appeared(":1.1"));
    try t.expect(!link.polling());
}

test "systemd absent at start, appearing later" {
    var link: Link = .{};
    // The proxies cannot be made: poll.
    try t.expect(!connect(&link, false, false));
    try t.expect(link.polling());
    // systemd appears: connect again, keep polling until it is whole.
    try t.expect(link.appeared(":1.1"));
    try t.expect(link.begin());
    try t.expect(link.polling());
    _ = link.subscribeResult(link.attempt, true);
    try t.expect(link.polling());
    _ = link.serviceResult(link.attempt, true);
    try t.expect(link.polling());
    _ = link.unitResult(link.attempt, true);
    try t.expect(!link.polling());
}

test "the unit's proxy failing keeps polling, and each poll retries" {
    var link: Link = .{};
    _ = link.appeared(":1.1");
    _ = connect(&link, false, true);
    try t.expect(link.polling());
    // Nothing on the bus changes, so the poll is what retries.
    try t.expect(link.retry());
    try t.expect(link.begin());
    // Not while an attempt is under way.
    try t.expect(!link.retry());
    _ = link.subscribeResult(link.attempt, true);
    _ = link.serviceResult(link.attempt, true);
    _ = link.unitResult(link.attempt, true);
    try t.expect(!link.polling());
    try t.expect(!link.retry());
    // systemd away: no point retrying until it is back.
    link.vanished();
    try t.expect(link.polling());
    try t.expect(!link.retry());
}

test "a failed Subscribe after systemd changed owner keeps polling" {
    var link: Link = .{};
    _ = link.appeared(":1.1");
    _ = connect(&link, true, true);
    try t.expect(!link.polling());
    // systemd re-executes: it leaves the bus and comes back as another name.
    link.vanished();
    try t.expect(link.polling());
    try t.expect(link.appeared(":1.7"));
    try t.expect(link.begin());
    _ = link.unitResult(link.attempt, true);
    _ = link.serviceResult(link.attempt, true);
    _ = link.subscribeResult(link.attempt, false);
    try t.expect(link.polling());
    // Another reappearance retries, and a whole connection stops the poll.
    link.vanished();
    try t.expect(link.appeared(":1.9"));
    _ = connect(&link, true, true);
    try t.expect(!link.polling());
}

test "an owner change during an attempt connects again once it is over" {
    var link: Link = .{};
    _ = link.appeared(":1.1");
    try t.expect(link.begin());
    const old = link.attempt;
    // systemd changes owner while the attempt is pending.
    link.vanished();
    try t.expect(!link.appeared(":1.4"));
    try t.expect(!link.begin());
    _ = link.subscribeResult(old, true);
    _ = link.serviceResult(old, true);
    // The attempt ends: connect again, to the new owner.
    try t.expect(link.unitResult(old, true));
    try t.expect(link.polling());
    try t.expect(link.begin());
    // Results of a superseded attempt are ignored.
    try t.expect(!link.unitResult(old, false));
    _ = link.subscribeResult(link.attempt, true);
    _ = link.serviceResult(link.attempt, true);
    _ = link.unitResult(link.attempt, true);
    try t.expect(!link.polling());
}
