//! Aqueous frontend metadata and mutations. Large documents use chunk transfers.
const p = @import("editor_protocol.zig");
const c = @import("../config/aqueous_contract.zig");
pub const Action = struct {
    operation: []const u8,
    expected_draft_revision: []const u8,
    version: []const u8,
    action: enum { refresh, validate, apply, discard, rebase, reload, keep, revert },
};
pub const State = struct {
    version: []const u8,
    revision: []const u8,
    review_version: []const u8,
    review_revision: ?[]const u8,
    report_version: []const u8,
    live: bool,
    draft: bool,
    busy: bool,
    locked: bool,
    can_record: bool,
    can_reload: bool,
    conflict: bool,
    unresolved: bool,
    outcome: enum { idle, loaded, validated, saved, reverted, invalidated, failed, uncertain },
    reload_state: enum { not_requested, pending, applied, unavailable, failed, unknown },
    toolkit: enum { not_requested, synced, partial, unknown },
    save_state: ?c.Save,
    receipt: ?c.Receipt,
    display_state: c.Display,
    impact_route: c.Route,
    error_code: ?[]const u8,
    detail: []const u8,
    phase: u8,
    seconds: u32,
    owns_preview: bool,
};
