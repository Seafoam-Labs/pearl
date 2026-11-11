//! Bounded GTK-owner bookkeeping. No filesystem access and no timer/owner holds.
const std = @import("std");
const model = @import("../workspace/model.zig");
const hashField = @import("../workspace/settings.zig").hashField;
pub const Key = [32]u8;
pub const limit = 128;
pub fn same(left: Key, right: Key) bool {
    return std.mem.eql(u8, &left, &right);
}
pub fn workspaceKey(m: *const model.Model) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "coral-language-workspace-v1");
    hashField(&hash, if (m.manifest_path != null) "manifest" else "roots");
    if (m.manifest_path) |path| hashField(&hash, path) else for (m.roots) |root| hashField(&hash, root.lexical_path);
    return hash.finalResult();
}
pub fn candidateKey(workspace: Key, lexical_root: []const u8, language: []const u8) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "coral-language-candidate-v1");
    hashField(&hash, &workspace);
    hashField(&hash, lexical_root);
    hashField(&hash, language);
    return hash.finalResult();
}
pub const Candidate = struct {
    key: Key,
    configuration: ?Key = null,
    workspace: ?Key = null,
    approved: bool = false,
    failed: bool = false,
};
pub const State = struct {
    candidates: [limit]Candidate = undefined,
    len: usize = 0,
    cursor: usize = 0,
    paused: bool = false,
    workspace: ?Key = null,
    pub fn candidate(self: *State, key: Key, configuration: Key) !*Candidate {
        for (self.candidates[0..self.len]) |*entry| if (same(entry.key, key)) {
            if (entry.configuration == null or !same(entry.configuration.?, configuration)) entry.* = .{ .key = key, .configuration = configuration, .workspace = self.workspace };
            return entry;
        };
        if (self.len == limit) return error.LanguageCandidateLimit;
        self.candidates[self.len] = .{ .key = key, .configuration = configuration, .workspace = self.workspace };
        self.len += 1;
        return &self.candidates[self.len - 1];
    }
    pub fn resetFailure(self: *State, key: Key) void {
        for (self.candidates[0..self.len]) |*entry| if (same(entry.key, key)) {
            entry.failed = false;
        };
    }
};

// Pending/failed Stop intent must outlive its window and cannot be cleared by a
// disk read. After publication, disk is authoritative again, including a resume
// from another process. Epochs reject reads started before a local transition.
const Pause = struct {
    key: Key,
    state: enum { pending, failed, durable, running },
    revision: u64,
    epoch: u64,
};
var pauses: [limit]Pause = undefined;
var pause_len: usize = 0;
var pause_saturated = false;
pub fn paused(key: Key) bool {
    for (pauses[0..pause_len]) |entry| if (same(entry.key, key)) return entry.state != .running;
    return pause_saturated;
}
pub fn revision(key: Key) u64 {
    for (pauses[0..pause_len]) |entry| if (same(entry.key, key)) return entry.revision;
    return 0;
}
pub fn epoch(key: Key) u64 {
    for (pauses[0..pause_len]) |entry| if (same(entry.key, key)) return entry.epoch;
    return 0;
}
pub fn pause(key: Key) !u64 {
    for (pauses[0..pause_len]) |*entry| if (same(entry.key, key)) {
        entry.state = .pending;
        entry.epoch += 1;
        entry.revision += 1;
        return entry.revision;
    };
    if (pause_len == limit) {
        pause_saturated = true;
        return error.LanguagePauseLimit;
    }
    pauses[pause_len] = .{ .key = key, .state = .pending, .revision = 1, .epoch = 1 };
    pause_len += 1;
    return 1;
}
pub fn pauseWritten(key: Key, expected_revision: u64) void {
    for (pauses[0..pause_len]) |*entry| if (same(entry.key, key) and entry.revision == expected_revision) {
        entry.state = .durable;
        entry.epoch += 1;
    };
}
pub fn pauseFailed(key: Key, expected_revision: u64) void {
    for (pauses[0..pause_len]) |*entry| if (same(entry.key, key) and entry.revision == expected_revision) {
        entry.state = .failed;
        entry.epoch += 1;
    };
}
/// A stale observation authorizes nothing. In particular, a read queued before
/// a Stop write cannot clear that Stop after its publication callback runs.
pub fn observePause(key: Key, expected_epoch: u64, disk_paused: bool) ?bool {
    if (epoch(key) != expected_epoch) return null;
    for (pauses[0..pause_len]) |*entry| if (same(entry.key, key)) {
        if (entry.state == .pending or entry.state == .failed) return true;
        const next: @TypeOf(entry.state) = if (disk_paused) .durable else .running;
        if (entry.state != next) {
            entry.state = next;
            entry.epoch += 1;
        }
        return disk_paused or pause_saturated;
    };
    return disk_paused or pause_saturated;
}
pub fn unpause(key: Key, expected_revision: u64) bool {
    if (revision(key) != expected_revision) return false;
    for (pauses[0..pause_len]) |*entry| if (same(entry.key, key)) {
        entry.state = .running;
        entry.epoch += 1;
    };
    return !pause_saturated;
}

/// Busy is contention, not a failed publication. Keep the owning job/hold and
/// retry indefinitely at a capped rate; permanent errors never enter this path.
pub const PauseRetry = struct {
    attempts: usize = 0,
    due: i64 = 0,
    pub fn busy(self: *PauseRetry, now: i64) void {
        const shift: u6 = @intCast(@min(self.attempts, 5));
        const delay = @min(@as(i64, 50_000) << shift, 1_000_000);
        self.attempts +|= 1;
        self.due = now + delay;
    }
    pub fn ready(self: PauseRetry, now: i64) bool {
        return now >= self.due;
    }
};

const Review = struct { key: Key, owner: ?*anyopaque = null, declined: bool = false };
var reviews: [limit]Review = undefined;
var review_len: usize = 0;
pub fn blocked(key: Key, owner: *anyopaque) bool {
    for (reviews[0..review_len]) |entry| if (same(entry.key, key)) return entry.declined or (entry.owner != null and entry.owner != owner);
    return review_len == limit;
}
pub fn claim(key: Key, owner: *anyopaque, explicit: bool) !void {
    for (reviews[0..review_len]) |*entry| if (same(entry.key, key)) {
        if (entry.owner != null and entry.owner != owner) return error.LanguageReviewAlreadyOpen;
        if (entry.declined and !explicit) return error.LanguageApprovalDeclined;
        entry.declined = false;
        entry.owner = owner;
        return;
    };
    if (review_len == limit) return error.LanguageReviewLimit;
    reviews[review_len] = .{ .key = key, .owner = owner };
    review_len += 1;
}
pub fn retry(key: Key) void {
    for (reviews[0..review_len]) |*entry| if (same(entry.key, key)) {
        entry.declined = false;
    };
}
pub fn release(owner: *anyopaque, decline: bool) void {
    for (reviews[0..review_len]) |*entry| if (entry.owner == owner) {
        entry.owner = null;
        entry.declined = decline;
    };
}
