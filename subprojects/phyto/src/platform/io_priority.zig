//! Linux scheduling priority for background transfer workers.
//!
//! A large copy runs on a GTask pool thread (see operations.zig), so it never
//! blocks the GTK main loop. It can still saturate the storage device and a CPU
//! core (the in-stream content hashing) and starve interactive work — a game
//! streaming assets or a browser buffering video — which is what makes the whole
//! system hitch during a big transfer (issue #124). Lowering the worker's I/O
//! priority to the lowest best-effort level and nudging its CPU nice lets
//! interactive work win while the copy still makes progress. Both previous values
//! are captured and restored so the shared pool thread is left as it was found.
//!
//! This is a no-op on non-Linux platforms; Aqueous sessions are Linux-only, but the
//! engine builds elsewhere for tests.
const std = @import("std");
const builtin = @import("builtin");

pub const Saved = struct {
    ioprio_valid: bool = false,
    ioprio: usize = 0,
    nice_valid: bool = false,
    nice: c_int = 0,
};

const IOPRIO_WHO_PROCESS = 1;
const IOPRIO_CLASS_SHIFT = 13;
const IOPRIO_CLASS_BE = 2;
// Lowest best-effort data level (0-7). Best-effort is preferred over the idle
// class so a busy disk cannot starve the transfer entirely.
const IOPRIO_BE_LOW = 7;

const PRIO_PROCESS = 0;
// Modest CPU deprioritisation: enough to yield to a game, not so much that the
// transfer stalls when cores are free.
const NICE_STEP = 5;
const NICE_MAX = 19;

// libc wrappers are used for nice because getpriority returns -1 both for a real
// error and for a legitimate nice of -1; errno disambiguates. (The engine already
// calls libc realpath directly, so this follows the existing convention.)
extern "c" fn getpriority(which: c_int, who: c_int) c_int;
extern "c" fn setpriority(which: c_int, who: c_int, prio: c_int) c_int;
extern "c" fn __errno_location() *c_int;

fn ioprioValue(class: usize, data: usize) usize {
    return (class << IOPRIO_CLASS_SHIFT) | data;
}

/// Lower the calling thread's I/O and CPU priority. Returns the prior values for
/// restore().
pub fn lower() Saved {
    if (builtin.os.tag != .linux) return .{};
    var saved: Saved = .{};
    const linux = std.os.linux;

    const current = linux.syscall2(.ioprio_get, IOPRIO_WHO_PROCESS, 0);
    if (linux.errno(current) == .SUCCESS) {
        const rc = linux.syscall3(.ioprio_set, IOPRIO_WHO_PROCESS, 0, ioprioValue(IOPRIO_CLASS_BE, IOPRIO_BE_LOW));
        if (linux.errno(rc) == .SUCCESS) {
            saved.ioprio_valid = true;
            saved.ioprio = current;
        }
    }

    const errno_ptr = __errno_location();
    errno_ptr.* = 0;
    const nice = getpriority(PRIO_PROCESS, 0);
    if (errno_ptr.* == 0) {
        const target = @min(nice + NICE_STEP, NICE_MAX);
        if (setpriority(PRIO_PROCESS, 0, target) == 0) {
            saved.nice_valid = true;
            saved.nice = nice;
        }
    }

    return saved;
}

/// Restore values captured by lower(). No-op for anything that was not changed.
pub fn restore(saved: Saved) void {
    if (builtin.os.tag != .linux) return;
    if (saved.ioprio_valid) {
        _ = std.os.linux.syscall3(.ioprio_set, IOPRIO_WHO_PROCESS, 0, saved.ioprio);
    }
    if (saved.nice_valid) {
        _ = setpriority(PRIO_PROCESS, 0, saved.nice);
    }
}

test "lower and restore round-trip safely across repeated cycles" {
    // Pool threads are reused, so repeated lower/restore must be safe whether or
    // not the platform permits the priority changes (failures are graceful).
    const first = lower();
    if (builtin.os.tag == .linux and first.ioprio_valid) {
        const cur = std.os.linux.syscall2(.ioprio_get, IOPRIO_WHO_PROCESS, 0);
        try std.testing.expectEqual(IOPRIO_CLASS_BE, cur >> IOPRIO_CLASS_SHIFT);
        try std.testing.expectEqual(IOPRIO_BE_LOW, cur & ((1 << IOPRIO_CLASS_SHIFT) - 1));
    }
    restore(first);
    const second = lower();
    restore(second);
    try std.testing.expectEqual(first.ioprio_valid, second.ioprio_valid);
    try std.testing.expectEqual(first.nice_valid, second.nice_valid);
}
