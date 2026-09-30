//! Bounded support report: file naming, retention and assembly. Pure; the
//! control server gathers the section bytes, writes the file and evicts old
//! reports. A missing source degrades to a marker line instead of failing the
//! report, because a broken subsystem is exactly when a report is needed.
const std = @import("std");
const diagnostics = @import("../diagnostics/safe_text.zig");

/// Reports retained in the state directory; older ones are deleted on write.
pub const keep = 3;
pub const prefix = "report-";
pub const suffix = ".log";
pub const header = "=== pearl report ===";
pub const footer = "=== report complete exit=0 ===";

pub const Sections = struct {
    argv: []const u8,
    version: []const u8,
    environment: []const u8,
    environment_exit: u8,
    /// Must already have its session token fingerprinted via `redactSession`.
    status: []const u8,
    journal: Journal,
};

/// One user-journal excerpt with the query that produced it, so the section
/// header is always a command that reproduces what follows.
pub const Journal = struct {
    /// Full command line, echoed as the section header: the query whose `text`
    /// follows, or the primary one when nothing matched.
    command: []const u8,
    /// Journal entries. Empty means `command` ran and matched nothing.
    text: []const u8,
    /// Non-null when no excerpt could be produced: no query was runnable, or
    /// every query that ran failed. The payload is journalctl's own first error
    /// line (or a helper failure name), so a broken journal is not mistaken for
    /// an empty one.
    unavailable: ?[]const u8 = null,
};

/// The user unit expected to carry this process' journal stream: the innermost
/// `.service` component of its own cgroup path. Returns `null` when the shell
/// runs outside a user service (a login scope, a delegated subtree, a container
/// without cgroup v2 paths), where the `_EXE=` query takes over.
///
/// Only `.service` leaves qualify. A transient `.scope` is the terminal or login
/// session the shell happened to be started from, so filtering by it would put
/// unrelated programs' output into a file the docs tell users to attach to a
/// public issue.
pub fn unitFromCgroup(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // `<id>:<controllers>:<path>` for cgroup v1, `0::<path>` for v2; the
        // path itself never contains a colon, so the last one ends the header.
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        var path = line[colon + 1 ..];
        while (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse continue;
        const unit = path[slash + 1 ..];
        if (!std.mem.endsWith(u8, unit, ".service") or !validUnitName(unit)) continue;
        return unit;
    }
    return null;
}

/// The unit name reaches the report header and a subprocess argument, so only a
/// conservative subset of systemd's charset is accepted: `:` (the cgroup-line
/// delimiter here) and `\` (escaped names are not decoded) are left out.
fn validUnitName(candidate: []const u8) bool {
    // systemd's UNIT_NAME_MAX; a leaf at or beyond it is not a name it assigned.
    if (candidate.len >= 256 or candidate.len <= ".service".len) return false;
    for (candidate) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '@', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// `report-<YYYYMMDDTHHMMSSZ>.log`; fixed width, so name order is time order.
pub fn name(seconds: u64, storage: *[32]u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    var writer = std.Io.Writer.fixed(storage);
    writer.print("{s}{:0>4}{:0>2}{:0>2}T{:0>2}{:0>2}{:0>2}Z{s}", .{ prefix, year_day.year, month_day.month.numeric(), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(), suffix }) catch unreachable;
    return writer.buffered();
}

/// Names to delete so at most `keep` reports remain, newest first. Only
/// `report-*.log` entries participate; anything else in the directory is
/// ignored. The returned slice is owned by the caller; the names alias `names`.
pub fn evictList(alloc: std.mem.Allocator, names: []const []const u8) ![][]const u8 {
    var reports: std.ArrayList([]const u8) = .empty;
    defer reports.deinit(alloc);
    for (names) |candidate| {
        if (!std.mem.startsWith(u8, candidate, prefix) or !std.mem.endsWith(u8, candidate, suffix)) continue;
        try reports.append(alloc, candidate);
    }
    std.mem.sort([]const u8, reports.items, {}, struct {
        fn newer(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .gt;
        }
    }.newer);
    const doomed = if (reports.items.len > keep) reports.items[keep..] else reports.items[0..0];
    return alloc.dupe([]const u8, doomed);
}

/// The status JSON legitimately carries the live IPC session token for its
/// caller, but a report is meant to be attached to bug reports: the token
/// value is replaced with the same irreversible fingerprint the journal uses.
/// Only the exact `"session":"` key matches; `"session_active":` and friends
/// do not.
pub fn redactSession(alloc: std.mem.Allocator, status: []const u8) ![]const u8 {
    const key = "\"session\":\"";
    const start = std.mem.indexOf(u8, status, key) orelse return status;
    const value = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, status, value, '"') orelse return status;
    return std.fmt.allocPrint(alloc, "{s}{f}{s}", .{ status[0..value], diagnostics.fingerprint(status[value..end]), status[end..] });
}

/// The journal text and the query line both come from outside the shell (the unit
/// name is read from its own cgroup), so both pass through the log redactor:
/// control bytes cannot fake report structure and oversized lines are cut.
pub fn write(writer: *std.Io.Writer, sections: Sections) std.Io.Writer.Error!void {
    try writer.print("{s}\nversion={s}\nargv={f}\n", .{ header, sections.version, diagnostics.safe(sections.argv) });
    try writer.print("=== check-environment exit={d} ===\n{s}\n", .{ sections.environment_exit, sections.environment });
    try writer.print("=== pearlctl status ===\n{s}\n", .{sections.status});
    try writer.print("=== {f} ===\n", .{diagnostics.safe(sections.journal.command)});
    if (sections.journal.unavailable) |reason| {
        if (reason.len == 0) {
            try writer.writeAll("journal=unavailable\n");
        } else {
            try writer.print("journal=unavailable reason={f}\n", .{diagnostics.safe(reason)});
        }
    } else if (sections.journal.text.len == 0) {
        try writer.writeAll("journal=no-entries\n");
    } else {
        var lines = std.mem.splitScalar(u8, sections.journal.text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try writer.print("{f}\n", .{diagnostics.safe(line)});
        }
    }
    try writer.writeAll(footer ++ "\n");
}

test "name renders a fixed-width sortable utc timestamp" {
    var storage: [32]u8 = undefined;
    try std.testing.expectEqualStrings("report-19700101T000000Z.log", name(0, &storage));
    try std.testing.expectEqualStrings("report-20010909T014640Z.log", name(1_000_000_000, &storage));
    try std.testing.expectEqualStrings("report-20240229T000000Z.log", name(1_709_164_800, &storage));
}

test "eviction keeps the newest reports and ignores other files" {
    const t = std.testing;
    const names = [_][]const u8{ "report-20260101T000000Z.log", "report-20260103T000000Z.log", "themes", "report-20260102T000000Z.log", "report-20260105T000000Z.log", "notes.log", "report-20260104T000000Z.log" };
    const doomed = try evictList(t.allocator, &names);
    defer t.allocator.free(doomed);
    try t.expectEqual(@as(usize, 2), doomed.len);
    try t.expectEqualStrings("report-20260102T000000Z.log", doomed[0]);
    try t.expectEqualStrings("report-20260101T000000Z.log", doomed[1]);
    const few = try evictList(t.allocator, &.{ "report-20260101T000000Z.log", "other" });
    defer t.allocator.free(few);
    try t.expectEqual(@as(usize, 0), few.len);
}

test "the session token never survives into the report" {
    const t = std.testing;
    const token = "94df34358656040baac921dc6afa1bb3";
    const status = "{\"session_active\":false,\"session\":\"" ++ token ++ "\",\"availability\":\"ready\"}";
    const redacted = try redactSession(t.allocator, status);
    defer t.allocator.free(redacted);
    try t.expect(std.mem.indexOf(u8, redacted, token) == null);
    try t.expect(std.mem.indexOf(u8, redacted, "\"session\":\"") != null);
    try t.expect(std.mem.indexOf(u8, redacted, "\"session_active\":false") != null);
    try t.expect(std.mem.indexOf(u8, redacted, "\"availability\":\"ready\"}") != null);
    // Stable for the same token, different for another.
    const again = try redactSession(t.allocator, status);
    defer t.allocator.free(again);
    try t.expectEqualStrings(redacted, again);
    const other = try redactSession(t.allocator, "{\"session\":\"00000000000000000000000000000000\"}");
    defer t.allocator.free(other);
    try t.expect(!std.mem.eql(u8, redacted, other));
    // Statuses without the key pass through unchanged.
    const plain = try redactSession(t.allocator, "{\"availability\":\"ready\"}");
    try t.expectEqualStrings("{\"availability\":\"ready\"}", plain);
}

test "the unit is the innermost service in the process cgroup" {
    const t = std.testing;
    // Aqueous integration unit and Pearl's own packaged unit, both cgroup v2.
    try t.expectEqualStrings("aqueous-git-pearl.service", unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/aqueous-git-pearl.service\n").?);
    try t.expectEqualStrings("pearl-git.service", unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/session.slice/pearl-git.service").?);
    // Instances keep their identifier.
    try t.expectEqualStrings("getty@tty1.service", unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/getty@tty1.service/\n").?);
    // cgroup v1 hierarchies carry the path after the second colon.
    try t.expectEqualStrings("pearl.service", unitFromCgroup("12:pids:/user.slice/user-1000.slice/user@1000.service/session.slice/pearl.service\n1:name=systemd:/user.slice/user-1000.slice/user@1000.service/session.slice/pearl.service\n").?);
    // A scope, a slice, a delegated subtree and a bare root are not Pearl's unit:
    // filtering by them would pull other people's streams into the report.
    try t.expect(unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/session.slice/kitty-5228-0.scope\n") == null);
    try t.expect(unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice\n") == null);
    try t.expect(unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/pearl.service/payload\n") == null);
    try t.expect(unitFromCgroup("0::/\n") == null);
    try t.expect(unitFromCgroup("") == null);
    try t.expect(unitFromCgroup("garbage without colons\n") == null);
    // Only unit-name characters survive: a cgroup is a path, not a place to put a
    // header or an argument.
    try t.expect(unitFromCgroup("0::/user.slice/x.service\n") != null);
    try t.expect(unitFromCgroup("0::/user.slice/a b.service\n") == null);
    try t.expect(unitFromCgroup("0::/user.slice/esc\x1b[1m.service\n") == null);
    try t.expect(unitFromCgroup("0::/user.slice/.service\n") == null);
    // The bound is systemd's UNIT_NAME_MAX: a leaf just under it is still a
    // name, one at or beyond it is not.
    const head = "0::/user.slice/";
    var long_name: [200]u8 = undefined;
    @memset(&long_name, 'a');
    @memcpy(long_name[0..head.len], head);
    @memcpy(long_name[long_name.len - ".service".len ..], ".service");
    try t.expect(unitFromCgroup(&long_name) != null);
    var oversized: [300]u8 = undefined;
    @memset(&oversized, 'a');
    @memcpy(oversized[0..head.len], head);
    @memcpy(oversized[oversized.len - ".service".len ..], ".service");
    try t.expect(unitFromCgroup(&oversized) == null);
}

test "assembly carries markers and degrades a missing journal" {
    const t = std.testing;
    const full: Sections = .{
        .argv = "pearl",
        .version = "1.0.0-rc.2",
        .environment = "Aqueous session environment is valid.",
        .environment_exit = 0,
        .status = "{\"availability\":\"ready\"}",
        .journal = .{
            .command = "journalctl --user -u aqueous-git-pearl.service -n 500 --no-pager",
            .text = "Sep 29 07:31:12 host pearl[9]: ts=2026-09-29T04:31:12Z pid=9 info(core): event=ready\n",
        },
    };
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try write(&writer, full);
    const text = writer.buffered();
    try t.expect(std.mem.startsWith(u8, text, header ++ "\n"));
    try t.expect(std.mem.endsWith(u8, text, footer ++ "\n"));
    try t.expect(std.mem.indexOf(u8, text, "version=1.0.0-rc.2\nargv=pearl\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "=== check-environment exit=0 ===\nAqueous session environment is valid.\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "=== pearlctl status ===\n{\"availability\":\"ready\"}\n") != null);
    // The header is the query that produced the excerpt, so it can be re-run.
    try t.expect(std.mem.indexOf(u8, text, "=== journalctl --user -u aqueous-git-pearl.service -n 500 --no-pager ===\nSep 29 07:31:12") != null);
    try t.expect(std.mem.indexOf(u8, text, "event=ready\n=== ") != null);
    try t.expect(std.mem.indexOf(u8, text, "journal=unavailable") == null);
    try t.expect(std.mem.indexOf(u8, text, "journal=no-entries") == null);

    var degraded_storage: [8192]u8 = undefined;
    var degraded = std.Io.Writer.fixed(&degraded_storage);
    const broken: Sections = .{ .argv = "pearl", .version = "1.0.0-rc.2", .environment = "Pearl requires a Wayland display.", .environment_exit = 2, .status = "{\"unavailable\":true}", .journal = .{ .command = "journalctl --user -u pearl.service -n 500 --no-pager", .text = "", .unavailable = "" } };
    try write(&degraded, broken);
    try t.expect(std.mem.indexOf(u8, degraded.buffered(), "=== check-environment exit=2 ===\nPearl requires a Wayland display.\n") != null);
    try t.expect(std.mem.indexOf(u8, degraded.buffered(), "journal=unavailable\n" ++ footer) != null);

    // A query that ran and matched nothing is not the same as an unreadable one,
    // and a reason says which.
    var empty_storage: [8192]u8 = undefined;
    var empty_writer = std.Io.Writer.fixed(&empty_storage);
    const empty: Sections = .{ .argv = "pearl", .version = "1.0.0-rc.2", .environment = "Aqueous session environment is valid.", .environment_exit = 0, .status = "{}", .journal = .{ .command = "journalctl --user -u pearl-greeter.service -n 500 --no-pager", .text = "" } };
    try write(&empty_writer, empty);
    try t.expect(std.mem.indexOf(u8, empty_storage[0..], "=== journalctl --user -u pearl-greeter.service -n 500 --no-pager ===\njournal=no-entries\n" ++ footer) != null);
    var reason_storage: [8192]u8 = undefined;
    var reason_writer = std.Io.Writer.fixed(&reason_storage);
    const refused: Sections = .{ .argv = "pearl", .version = "1.0.0-rc.2", .environment = "Aqueous session environment is valid.", .environment_exit = 0, .status = "{}", .journal = .{ .command = "journalctl --user -u pearl.service -n 500 --no-pager", .text = "", .unavailable = "No journal files were found." } };
    try write(&reason_writer, refused);
    try t.expect(std.mem.indexOf(u8, reason_storage[0..], "journal=unavailable reason=No journal files were found.\n" ++ footer) != null);
}

test "journal lines cannot fake report structure" {
    const t = std.testing;
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const sections: Sections = .{
        .argv = "pearl\x1b[1m",
        .version = "1.0.0-rc.2",
        .environment = "Aqueous session environment is valid.",
        .environment_exit = 0,
        .status = "{}",
        .journal = .{
            .command = "journalctl --user -u pea\x1brl.service -n 500 --no-pager",
            .text = "line\x1b[one\n" ++ "x" ** 600,
        },
    };
    try write(&writer, sections);
    const text = writer.buffered();
    try t.expect(std.mem.indexOf(u8, text, "\x1b") == null);
    try t.expect(std.mem.indexOf(u8, text, "argv=pearl?[1m\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "=== journalctl --user -u pea?rl.service -n 500 --no-pager ===\nline?[one\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "…[truncated]") != null);
    // The long line stayed one line: exactly one newline between it and the footer.
    const tail = std.mem.indexOf(u8, text, "x" ** 100).?;
    const end = std.mem.indexOf(u8, text[tail..], footer).? + tail;
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text[tail..end], "\n"));
}
