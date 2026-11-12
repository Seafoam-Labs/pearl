//! Native main-context policy owner. Workers borrow no model, document or GTK
//! state. One active job, one coalesced recheck, bounded serialized revocations.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const model = @import("model.zig");
const routing = @import("identity.zig");
pub const trust = @import("trust.zig");
const fs = @import("trust_fs.zig");
const settings = @import("settings.zig");
const test_hooks = @import("build_options").test_hooks;

pub const Status = enum { restricted, verifying, trusted, failed };
const Kind = enum { recheck, approve, revoke };
const Confirmation = struct { request: u64, model_generation: u64, key: trust.Fingerprint };
const KnownApproval = struct { scope: trust.Fingerprint, key: trust.Fingerprint, approved_revocation: u64 = 0 };

/// Immutable safe-user snapshot. Hash fields explicitly, never native padding.
/// The domain versions the schema, precedence and language-ID interpretation.
pub const UserPolicy = struct {
    values: settings.Baseline,
    present: settings.KeyMask,

    fn capture(app: *const App) UserPolicy {
        return .{ .values = app.settings.baseline(), .present = app.settings.present };
    }
    fn same(self: UserPolicy, other: UserPolicy) bool {
        return std.meta.eql(self.values, other.values) and std.meta.eql(self.present, other.present);
    }
    pub fn digest(self: UserPolicy, model_digest: trust.PolicyDigest) trust.PolicyDigest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        settings.hashField(&hash, "coral-native-effective-policy-v2");
        settings.hashField(&hash, "defaults>explicit-user>workspace>folder>workspace-language>folder-language;GtkSource-ID;indent=1..8");
        settings.hashField(&hash, &model_digest);
        const defaults: settings.Baseline = .{};
        inline for (.{ "lines", "wrap", "spaces", "indent" }) |key| {
            settings.hashField(&hash, key);
            const default: u8 = if (comptime std.mem.eql(u8, key, "indent")) defaults.indent else @intFromBool(@field(defaults, key));
            const value: u8 = if (comptime std.mem.eql(u8, key, "indent")) self.values.indent else @intFromBool(@field(self.values, key));
            hash.update(&.{ default, @intFromBool(@field(self.present, key)), value });
        }
        return hash.finalResult();
    }
};

const Continuity = struct {
    workspace: trust.Fingerprint,
    initial: bool = true,
    expected: ?trust.Fingerprint = null,
    approval_required: bool = false,

    fn observe(self: *Continuity, key: trust.Fingerprint, initial_restore: bool) void {
        if (self.expected) |expected| {
            if (!trust.same(expected, key)) self.approval_required = true;
        } else if (initial_restore and !self.approval_required) {
            self.expected = key;
        } else self.approval_required = true;
    }
    fn approve(self: *Continuity, key: trust.Fingerprint) void {
        self.expected = key;
        self.initial = false;
        self.approval_required = false;
    }
};

pub const Controller = struct {
    app: *App,
    policy: trust.Policy,
    permit_scope: routing.Scope,
    user: UserPolicy,
    continuity: [trust.limits.records]Continuity = undefined,
    continuity_len: usize = 0,
    home: ?fs.StateHome = null,
    home_error: ?anyerror = null,
    status: Status = .restricted,
    store_error: ?[:0]u8 = null,
    error_is_revoke: bool = false,
    known: [trust.limits.records]KnownApproval = undefined,
    known_len: usize = 0,
    // If an association cannot be retained, do not let another owner approve
    // while this controller still has removal writes that could delete it.
    unscoped_removals: bool = false,
    identity: ?trust.Identity = null,
    active: ?*Job = null,
    pending: bool = false,
    closed: bool = false,
    request: u64 = 1,
    model_generation: u64 = 1,
    confirmation: ?Confirmation = null,
    // Lexical scope tombstones survive replacement models and policy changes.
    // Saturation fails closed for every scope rather than forgetting a revoke.
    blocked: trust.Records = .{},
    block_all: bool = false,
    revokes: trust.Records = .{},
    failed_revokes: trust.Records = .{},
    gate: ?trust.Permit = null,
    gate_cancelled: bool = false,
    retired_permit: ?trust.Permit = null,
    test_delay_us: u64 = 0,
    test_delivery_delay_us: u64 = 0,
    test_fail_write: bool = false,
    jobs_started: u64 = 0,
    jobs_reaped: u64 = 0,

    pub fn init(app: *App) Controller {
        const scope = routing.Scope.init();
        var self: Controller = .{ .app = app, .permit_scope = scope, .policy = .init(scope.capture().?), .user = UserPolicy.capture(app) };
        self.home = fs.StateHome.init(a, null) catch |err| blk: {
            self.home_error = err;
            break :blk null;
        };
        return self;
    }
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.active == null and self.revokes.len == 0);
        self.permit_scope.close();
        if (self.identity) |*id| id.deinit();
        if (self.home) |*home| home.deinit();
        if (self.store_error) |text| a.free(text);
    }
    pub fn shutdown(self: *Controller) void {
        self.invalidate();
        self.closed = true;
        self.pending = false;
        self.pump(); // Cleanup writes still hold the application after window close.
    }
    fn refreshStatus(self: *Controller) void {
        if (self.closed or self.app.closing or self.app.browser.closed) return;
        const text = u.fmt("Workspace: {s} · {s} · automatic language servers require exact configuration approval", .{ @tagName(self.policy.state), @tagName(self.status) });
        defer a.free(text);
        u.setLabel(self.app.browser.policy_status, text);
    }
    fn clearError(self: *Controller) void {
        if (self.store_error) |text| a.free(text);
        self.store_error = null;
        self.error_is_revoke = false;
    }
    fn fail(self: *Controller, err: anyerror) void {
        defer self.refreshStatus();
        self.status = .failed;
        self.clearError();
        self.store_error = if (err == error.WorkspaceMonitoringUnavailable)
            u.z("WorkspaceMonitoringUnavailable: root/manifest ancestry or policy watches are incomplete. Restricted; executable permits are unavailable. Check path availability and watch limits, then use Workspace: Rescan.")
        else
            u.fmt("{s}/coral/trust: {s}. Restricted. Check state-directory ownership/permissions. Use Workspace: Rescan after root/policy changes, Recheck for store errors, or Revoke to retry removal. A failed revoke may still exist on disk.", .{ if (self.home) |home| home.path else "(XDG_STATE_HOME/HOME unavailable)", @errorName(err) });
        if (!self.closed and !self.app.closing) self.app.message(self.store_error.?);
    }
    fn token(self: *Controller) routing.Token {
        return self.permit_scope.capture().?;
    }
    fn cancelGate(self: *Controller) void {
        if (self.gate) |permit| {
            self.gate_cancelled = true;
            if (test_hooks) self.retired_permit = permit;
        }
        self.gate = null;
    }
    fn remember(self: *Controller, scope: trust.Fingerprint, key: trust.Fingerprint) void {
        for (self.known[0..self.known_len]) |known| if (trust.same(known.scope, scope) and trust.same(known.key, key)) return;
        if (self.known_len == self.known.len) {
            self.block_all = true;
            self.policy.revoke();
            return;
        }
        self.known[self.known_len] = .{ .scope = scope, .key = key };
        self.known_len += 1;
    }
    fn block(self: *Controller, scope: trust.Fingerprint) void {
        self.blocked.approve(scope) catch {
            self.block_all = true;
        };
    }
    fn queueRevoke(self: *Controller, scope: ?trust.Fingerprint, key: trust.Fingerprint) void {
        // Retain the scope even for never-trusted identities, before deduping
        // queued/active writes. Models can disappear before these writes drain.
        if (scope) |value| self.remember(value, key);
        var associated = false;
        for (self.known[0..self.known_len]) |known| {
            if (trust.same(known.key, key) and (if (scope) |value| trust.same(known.scope, value) else true)) {
                associated = true;
                break;
            }
        }
        if (!associated) self.unscoped_removals = true;
        if (self.active) |job| if (job.kind == .revoke and trust.same(job.expected.?, key)) return;
        self.revokes.approve(key) catch {
            self.block_all = true;
            self.fail(error.RevocationQueueFull);
        };
    }
    /// Retire executable permits and their consumers synchronously. Callers must
    /// distinguish content-only notifications from identity/policy uncertainty;
    /// a later successful recheck cannot revive an issued permit or its service.
    pub fn invalidate(self: *Controller) void {
        if (self.app.language_initialized) self.app.language.invalidate();
        if (self.app.git_initialized) self.app.git.invalidate();
        if (self.app.git_initialized) {
            self.app.git_commit.invalidate();
            self.app.git_refs.invalidate();
            self.app.git_worktree.invalidate();
            self.app.git_stash.invalidate();
            self.app.git_conflict.invalidate();
            self.app.git_remote.invalidate();
            self.app.git_history.invalidate();
            self.app.git_panel.invalidate();
            self.app.git_project_diff.invalidate();
        }
        defer self.refreshStatus();
        self.request = std.math.add(u64, self.request, 1) catch @panic("Policy request generation exhausted");
        self.confirmation = null;
        self.cancelGate();
        if (self.active) |job| {
            job.cancelled.store(true, .release);
            if (job.kind == .approve) {
                self.block(job.scope_key);
                self.queueRevoke(job.scope_key, job.expected.?);
            }
        }
        _ = self.policy.begin(self.token()) catch {
            self.fail(error.GenerationExhausted);
            return;
        };
        self.pending = !self.closed;
        self.status = if (self.app.browser.model != null) .verifying else .restricted;
    }
    pub fn modelChanged(self: *Controller) void {
        self.model_generation = std.math.add(u64, self.model_generation, 1) catch @panic("Policy model generation exhausted");
        self.invalidate();
        // A replacement owner gets a fresh permit token, even for the same root
        // IDs. Local revoke tombstones are keyed separately and survive this.
        self.permit_scope.invalidate();
        self.policy = .init(self.token());
        if (self.identity) |*id| id.deinit();
        self.identity = null;
        if (!self.closed and !self.app.closing) self.app.refreshPolicySettings();
    }
    pub fn userSettingsChanged(self: *Controller) void {
        const next = UserPolicy.capture(self.app);
        if (self.user.same(next)) return;
        self.user = next;
        self.invalidate();
    }
    fn currentContinuity(self: *Controller) ?*const Continuity {
        const m = if (self.app.browser.model) |*m| m else return null;
        const workspace = workspaceKey(m);
        for (self.continuity[0..self.continuity_len]) |*entry| if (trust.same(entry.workspace, workspace)) return entry;
        return null;
    }
    fn continuityFor(self: *Controller, m: *const model.Model) !usize {
        const workspace = workspaceKey(m);
        for (self.continuity[0..self.continuity_len], 0..) |entry, i| if (trust.same(entry.workspace, workspace)) return i;
        if (self.continuity_len == self.continuity.len) return error.ContinuityLimit;
        const index = self.continuity_len;
        self.continuity[index] = .{ .workspace = workspace };
        self.continuity_len += 1;
        return index;
    }
    pub fn modelFailed(self: *Controller, err: anyerror) void {
        self.invalidate();
        self.pending = false;
        self.fail(err);
    }
    pub fn recheck(self: *Controller) void {
        if (self.closed) return;
        self.invalidate();
    }
    pub fn currentScope(self: *Controller) ?trust.Fingerprint {
        return if (self.app.browser.model) |*m| scopeKey(m) else null;
    }
    fn sharedRevocation(self: *Controller, scope: trust.Fingerprint) u64 {
        return if (self.app.manager) |manager| manager.revocationGeneration(scope) else 0;
    }
    fn sharedBlocked(self: *Controller, scope: trust.Fingerprint) bool {
        if (self.app.manager) |manager| if (manager.revocation_saturated) return true;
        const generation = self.sharedRevocation(scope);
        if (generation == 0) return false;
        for (self.known[0..self.known_len]) |known| {
            if (trust.same(known.scope, scope) and known.approved_revocation == generation) return false;
        }
        return true;
    }
    fn removalPending(self: *const Controller, scope: trust.Fingerprint, active_key: ?trust.Fingerprint) bool {
        if (self.unscoped_removals and (self.revokes.len != 0 or active_key != null)) return true;
        for (self.known[0..self.known_len]) |known| if (trust.same(known.scope, scope)) {
            if (self.revokes.contains(known.key)) return true;
            if (active_key) |key| if (trust.same(key, known.key)) return true;
        };
        return false;
    }
    pub fn scopeCleanupPending(self: *Controller, scope: trust.Fingerprint) bool {
        const active_key = if (self.active) |job| (if (job.kind == .revoke) job.expected else null) else null;
        if (self.removalPending(scope, active_key)) return true;
        // An old lookup can still discover a grant to remove; a cancelled
        // approval may have committed before cancellation reached its worker.
        if (self.currentScope()) |current| if (trust.same(current, scope)) {
            if (self.pending or self.revokes.len != 0) return true;
            if (self.active) |job| if (job.kind != .approve or job.cancelled.load(.acquire)) return true;
        };
        if (self.active) |job| {
            if (job.kind != .revoke and trust.same(job.scope_key, scope) and job.cancelled.load(.acquire)) return true;
        }
        return false;
    }
    fn sharedCleanupPending(self: *Controller) bool {
        const scope = self.currentScope() orelse return false;
        return if (self.app.manager) |manager| manager.scopeCleanupPending(scope) else false;
    }
    pub fn revoke(self: *Controller) void {
        if (self.closed) return;
        if (self.app.manager) |manager| if (self.currentScope()) |scope| {
            manager.revokeWorkspace(scope);
            return;
        };
        self.revokeLocal();
        self.pump();
    }
    /// Nonbroadcast half of explicit revoke. Manager completes this in every
    /// matching owner before starting any removal, including failed persistence.
    pub fn revokeLocal(self: *Controller) void {
        if (self.closed) return;
        const scope = self.currentScope();
        if (scope) |value| {
            self.block(value);
            for (self.known[0..self.known_len]) |known| if (trust.same(known.scope, value)) self.queueRevoke(value, known.key);
        }
        if (self.identity) |id| self.queueRevoke(scope, id.fingerprint);
        if (self.policy.key) |key| self.queueRevoke(scope, key);
        self.invalidate();
        self.policy.revoke();
        // Failed writes are retried only on an explicit Revoke, not a busy loop.
        for (self.failed_revokes.keys[0..self.failed_revokes.len]) |key| self.queueRevoke(null, key);
        self.pending = self.identity == null and self.app.browser.model != null;
        self.status = .restricted;
        self.app.message("Workspace trust revoked for this scope in all open windows. Fresh explicit confirmation is required; removal failures remain restricted.");
        self.refreshStatus();
    }
    /// Called from the existing GTK tick and after every reaped policy job.
    pub fn pump(self: *Controller) void {
        defer self.refreshStatus();
        if (self.active != null) return;
        if (self.revokes.len != 0) {
            const key = self.revokes.keys[0];
            self.revokes.revoke(key);
            self.start(.revoke, key) catch |err| {
                self.failed_revokes.approve(key) catch {
                    self.block_all = true;
                };
                self.fail(err);
                self.error_is_revoke = true;
            };
            return;
        }
        if (self.closed or !self.pending) return;
        if (self.app.browser.loading) return;
        if (self.app.browser.policy_pending) {
            if (self.app.browser.error_name != null) {
                self.pending = false;
                self.fail(error.WorkspaceRefreshRequired);
            }
            return;
        }
        self.pending = false;
        if (self.app.browser.model == null) {
            self.status = .restricted;
            return;
        }
        self.start(.recheck, null) catch |err| self.fail(err);
    }
    fn start(self: *Controller, kind: Kind, expected: ?trust.Fingerprint) !void {
        defer self.refreshStatus();
        if (self.home == null) return self.home_error orelse error.MissingStateHome;
        var inputs: ?trust.Inputs = null;
        errdefer if (inputs) |*value| value.deinit();
        var scope_key: trust.Fingerprint = @splat(0);
        var model_digest: trust.PolicyDigest = @splat(0);
        var continuity_index: ?usize = null;
        var initial_restore = false;
        var expected_key = expected;
        if (kind != .revoke) {
            const m = if (self.app.browser.model) |*m| m else return error.NoWorkspace;
            continuity_index = try self.continuityFor(m);
            const continuity = &self.continuity[continuity_index.?];
            if (kind == .recheck) {
                initial_restore = continuity.initial;
                expected_key = continuity.expected;
                // Failed/cancelled first checks cannot become fresh restorations.
                continuity.initial = false;
            }
            model_digest = m.policy_fingerprint;
            // Preserve the actionable unavailable-root diagnostic before the
            // broader monitoring gate; neither path can issue a permit.
            inputs = try inputsFor(m, self.user);
            if (!self.app.browser.watches.policyReady()) return error.WorkspaceMonitoringUnavailable;
            scope_key = scopeKey(m);
            if (self.sharedBlocked(scope_key)) {
                self.block(scope_key);
                continuity.approval_required = true;
                continuity.initial = false;
                // Never load an old grant into a new window while removal is
                // pending/failed. Capture identity for fresh confirmation only.
                // This also avoids deleting a peer's later explicit approval.
                if (kind == .recheck) {
                    initial_restore = false;
                    expected_key = null;
                }
            }
            if (self.block_all or self.blocked.contains(scope_key)) self.policy.revoke();
        }
        const ticket = if (kind == .approve) try self.policy.beginApproval(self.token(), .user_approved) else try self.policy.begin(self.token());
        const job = try a.create(Job);
        job.* = .{
            .controller = self,
            .kind = kind,
            .inputs = inputs,
            .expected = expected_key,
            .initial_restore = initial_restore,
            .continuity_index = continuity_index,
            .user = self.user,
            .model_digest = model_digest,
            .ticket = ticket,
            .request = self.request,
            .model_generation = self.model_generation,
            .model_token = if (self.app.browser.model) |*m| m.scope.capture() else null,
            .scope_key = scope_key,
            .delay_us = if (test_hooks) self.test_delay_us else 0,
            .delivery_delay_us = if (test_hooks) self.test_delivery_delay_us else 0,
            .fail_write = if (test_hooks) self.test_fail_write else false,
        };
        if (test_hooks) {
            self.test_delay_us = 0;
            self.test_delivery_delay_us = 0;
            self.test_fail_write = false;
        }
        self.active = job;
        self.jobs_started += 1;
        if (kind != .revoke) self.status = .verifying;
        self.cancelGate();
        self.app.hold();
        const task = c.g_task_new(null, null, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    pub fn canConfirm(self: *Controller) bool {
        return !self.closed and !self.block_all and self.active == null and !self.pending and self.revokes.len == 0 and self.identity != null and self.app.browser.model != null and !self.app.browser.loading and !self.app.browser.policy_pending and self.app.browser.watches.policyReady() and self.status != .failed and !self.sharedCleanupPending() and !(if (self.app.manager) |manager| manager.revocation_saturated else false);
    }
    /// Freeze the exact scope shown by the modal dialog. No approval occurs here.
    pub fn prepareConfirmation(self: *Controller) bool {
        if (!self.canConfirm()) {
            self.app.message("Trust is unavailable while verification or same-scope revocation cleanup is pending or failed. All roots must be available with complete identity/policy watches. Recheck or Rescan, then retry.");
            return false;
        }
        self.confirmation = .{ .request = self.request, .model_generation = self.model_generation, .key = self.identity.?.fingerprint };
        return true;
    }
    pub fn confirm(self: *Controller, approved: bool) void {
        const shown = self.confirmation orelse return;
        self.confirmation = null;
        if (!approved) return;
        if (!self.canConfirm() or shown.request != self.request or shown.model_generation != self.model_generation or !trust.same(shown.key, self.identity.?.fingerprint)) {
            self.app.message("Workspace changed while the trust dialog was open. Review the current roots and confirm again.");
            return;
        }
        self.start(.approve, shown.key) catch |err| self.fail(err);
    }
    /// Executable services obtain a permit and validate it at dispatch. Trust is
    /// only a precondition: service-specific user approval is still required.
    pub fn issue(self: *Controller, capability: trust.Capability) !trust.Permit {
        if (self.closed or self.block_all or self.revokes.len != 0 or self.active != null or self.pending or self.app.browser.loading or self.app.browser.policy_pending or !self.app.browser.watches.policyReady() or self.app.browser.model == null) return error.Restricted;
        if (self.sharedBlocked(self.currentScope().?)) return error.Restricted;
        return self.policy.issue(capability);
    }
    pub fn validate(self: *Controller, permit: trust.Permit, capability: trust.Capability) bool {
        return !self.closed and !self.block_all and self.revokes.len == 0 and self.active == null and !self.pending and !self.app.browser.loading and !self.app.browser.policy_pending and self.app.browser.watches.policyReady() and self.app.browser.model != null and !self.sharedBlocked(self.currentScope().?) and self.policy.validate(permit, self.token(), capability);
    }
    /// A fixture-only pending gate, not a task runner. Revoke/recheck/switch cancels it.
    pub fn fixtureGate(self: *Controller) void {
        if (!test_hooks) return;
        self.gate_cancelled = false;
        self.gate = self.issue(.tasks) catch null;
    }
    /// Native harness assertion fixture: checks actual widgets and the live
    /// capability gate without executing a service or manufacturing approval.
    pub fn fixtureCheck(self: *Controller) !void {
        if (!test_hooks) return;
        try validatePolicyContracts();
        for (self.app.views.items) |view| try checkWidget(view.widget, self.app.effectiveSettings(view.document));
        for (self.app.excerpts.items) |pane| try checkWidget(pane.editor.widget, self.app.effectiveSettings(pane.document));
        if (self.policy.state == .restricted) {
            if (self.issue(.tasks)) |_| return error.RestrictedPermitIssued else |err| if (err != error.Restricted) return err;
            if (self.gate != null) return error.RestrictedGatePending;
        }
        if (self.policy.state == .trusted) {
            const continuity = self.currentContinuity() orelse return error.TrustedWithoutContinuity;
            const expected = continuity.expected orelse return error.TrustedWithoutExpectedKey;
            const id = self.identity orelse return error.TrustedWithoutIdentity;
            if (continuity.approval_required or !trust.same(expected, id.fingerprint)) return error.TrustedAlternateIncarnation;
            const m = self.app.browser.model orelse return error.TrustedWithoutModel;
            if (!self.user.same(UserPolicy.capture(self.app)) or !trust.same(id.policy_digest, self.user.digest(m.policy_fingerprint))) return error.TrustedStaleUserPolicy;
        }
        if (self.retired_permit) |permit| if (self.validate(permit, .tasks)) return error.StalePermitAccepted;
        if (self.gate_cancelled and self.gate != null) return error.CancelledGatePending;
    }
    pub fn describe(self: *Controller) [:0]u8 {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        append(&text, "Trust: {s} ({s})\nLanguage servers start automatically only when workspace trust is valid and the exact user configuration and executable identity were previously approved. New or changed configurations require a Language: Start review. Stop all sessions pauses this workspace durably until Start or Restart. They run with your user permissions; workspace trust is NOT per-tool approval or an OS sandbox. Executables are configured only in ~/.config/coral/languages.json, never in the repository.\n\nSafe settings apply even in restricted mode. Precedence: defaults → explicit user → workspace → folder → workspace language → folder language (GtkSource ID). Font, theme and spelling stay global. Scratch/outside-root documents use defaults and explicit user settings only.\nFolder settings require explicit Workspace: Rescan; monitoring is not recursive.\n\nState store: {s}/coral/trust\n", .{ @tagName(self.policy.state), @tagName(self.status), if (self.home) |home| home.path else "(unavailable)" });
        if (self.store_error) |err| append(&text, "Error: {s}\n", .{err});
        if (self.identity) |id| append(&text, "Exact trust fingerprint: {s}\n", .{std.fmt.bytesToHex(&id.fingerprint, .lower)});
        if (self.currentContinuity()) |continuity| {
            if (continuity.expected) |expected| append(&text, "Expected workspace fingerprint: {s}\n", .{std.fmt.bytesToHex(&expected, .lower)});
            if (continuity.approval_required) append(&text, "Workspace identity or effective policy changed. Explicit approval is required; an alternate stored approval will not be restored.\n", .{});
        }
        if (self.app.browser.model) |*m| {
            const digest = self.user.digest(m.policy_fingerprint);
            append(&text, "\nWorkspace: {s}\nModel policy digest: {s}\nEffective policy digest (including explicit user/default semantics): {s}\n", .{ m.manifest_path orelse "Folder workspace", std.fmt.bytesToHex(&m.policy_fingerprint, .lower), std.fmt.bytesToHex(&digest, .lower) });
            for (m.roots, 0..) |root, i| {
                append(&text, "\nRoot {d}: {s}\nRequested: {s}\nCanonical: {s}\nAvailability: {s}\n", .{ i + 1, root.display_name, root.lexical_path, root.canonical_path orelse "(unavailable)", @tagName(root.availability) });
                if (self.identity) |id| if (i < id.roots.len) {
                    const dir = id.roots[i];
                    append(&text, "Verified identity: {s} [device {d}:{d}, inode {d}]\n", .{ dir.canonical, dir.dev_major, dir.dev_minor, dir.inode });
                };
                describeEffective(&text, m.effectiveSettings(root.id, null, self.app.settings.baseline(), self.app.settings.present));
            }
        } else append(&text, "\nNo workspace is open.\n", .{});
        if (self.app.active()) |d| {
            append(&text, "\nCurrent document: {s}\n", .{d.path orelse "Untitled (scratch)"});
            describeEffective(&text, self.app.effectiveSettings(d));
        }
        return u.z(text.items);
    }
    pub fn probe(self: *Controller) void {
        if (!test_hooks) return;
        const View = struct { id: u64, document: u64, excerpt: bool, lines: bool, wrap: bool, spaces: bool, indent: u32, indent_width: c_int };
        const Doc = struct { id: u64, path: ?[]const u8, revision: u64, dirty: bool, effective: settings.Effective, parser_attached: bool, presentation_limited: bool };
        var views: std.ArrayList(View) = .empty;
        defer views.deinit(a);
        var docs: std.ArrayList(Doc) = .empty;
        defer docs.deinit(a);
        for (self.app.documents.entries.items) |d| docs.append(a, .{ .id = d.id, .path = d.path, .revision = d.revision, .dirty = d.dirty(), .effective = self.app.effectiveSettings(d), .parser_attached = c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, d.buffer)) != null, .presentation_limited = d.large or @import("../editor/presentation_policy.zig").limited(d.buffer) }) catch unreachable;
        for (self.app.views.items) |v| {
            const source = u.cast(c.GtkSourceView, v.widget);
            views.append(a, .{ .id = v.id, .document = v.document.id, .excerpt = false, .lines = c.gtk_source_view_get_show_line_numbers(source) != 0, .wrap = c.gtk_text_view_get_wrap_mode(u.cast(c.GtkTextView, v.widget)) != c.GTK_WRAP_NONE, .spaces = c.gtk_source_view_get_insert_spaces_instead_of_tabs(source) != 0, .indent = c.gtk_source_view_get_tab_width(source), .indent_width = c.gtk_source_view_get_indent_width(source) }) catch unreachable;
        }
        for (self.app.excerpts.items) |pane| {
            const source = u.cast(c.GtkSourceView, pane.editor.widget);
            views.append(a, .{ .id = pane.id, .document = pane.document.id, .excerpt = true, .lines = c.gtk_source_view_get_show_line_numbers(source) != 0, .wrap = c.gtk_text_view_get_wrap_mode(u.cast(c.GtkTextView, pane.editor.widget)) != c.GTK_WRAP_NONE, .spaces = c.gtk_source_view_get_insert_spaces_instead_of_tabs(source) != 0, .indent = c.gtk_source_view_get_tab_width(source), .indent_width = c.gtk_source_view_get_indent_width(source) }) catch unreachable;
        }
        var permits: [6]bool = undefined;
        inline for (.{ trust.Capability.lsp, .tasks, .debug, .hooks, .extensions, .agent_tools }, 0..) |capability, i| {
            permits[i] = if (self.issue(capability)) |permit| self.validate(permit, capability) else |_| false;
        }
        const key_hex = if (self.identity) |id| std.fmt.bytesToHex(&id.fingerprint, .lower) else @as([64]u8, @splat(0));
        const policy_hex = if (self.app.browser.model) |m| std.fmt.bytesToHex(&m.policy_fingerprint, .lower) else @as([64]u8, @splat(0));
        const combined_hex = if (self.app.browser.model) |m| blk: {
            const digest = self.user.digest(m.policy_fingerprint);
            break :blk std.fmt.bytesToHex(&digest, .lower);
        } else @as([64]u8, @splat(0));
        const continuity = self.currentContinuity();
        const expected = if (continuity) |entry| entry.expected else null;
        const expected_hex = if (expected) |key| std.fmt.bytesToHex(&key, .lower) else @as([64]u8, @splat(0));
        const scope = self.currentScope();
        const scope_hex = if (scope) |key| std.fmt.bytesToHex(&key, .lower) else @as([64]u8, @splat(0));
        const text = std.json.Stringify.valueAlloc(a, .{
            .scope_key = if (scope != null) @as(?[]const u8, &scope_hex) else null,
            .shared_revocation_generation = if (scope) |key| self.sharedRevocation(key) else 0,
            .shared_revocation_blocked = if (scope) |key| self.sharedBlocked(key) else false,
            .shared_cleanup_pending = self.sharedCleanupPending(),
            .pending = @as(usize, @intFromBool(self.active != null)) + @intFromBool(self.pending) + self.revokes.len,
            .active = if (self.active) |job| @as(?[]const u8, @tagName(job.kind)) else null,
            .pending_recheck = self.pending,
            .queued_revokes = self.revokes.len,
            .failed_revokes = self.failed_revokes.len,
            .status = self.status,
            .trust = self.policy.state,
            .fingerprint = if (self.identity != null) @as(?[]const u8, &key_hex) else null,
            .policy_fingerprint = if (self.app.browser.model != null) @as(?[]const u8, &policy_hex) else null,
            .effective_policy_fingerprint = if (self.app.browser.model != null) @as(?[]const u8, &combined_hex) else null,
            .expected_fingerprint = if (expected != null) @as(?[]const u8, &expected_hex) else null,
            .approval_required = if (continuity) |entry| entry.approval_required else false,
            .initial_restore = if (self.active) |job| job.initial_restore else false,
            .continuity_count = self.continuity_len,
            .continuity_limit = @as(usize, trust.limits.records),
            .store_error = self.store_error,
            .request = self.request,
            .model_generation = self.model_generation,
            .policy_generation = self.policy.generation,
            .user_present = self.app.settings.present,
            .user_baseline = self.user.values,
            .active_user = if (self.active) |job| @as(?UserPolicy, job.user) else null,
            .documents = docs.items,
            .views = views.items,
            .permits = permits,
            .gate_pending = self.gate != null,
            .gate_valid = if (self.gate) |p| self.validate(p, .tasks) else false,
            .gate_cancelled = self.gate_cancelled,
            .retired_permit_valid = if (self.retired_permit) |p| self.validate(p, .tasks) else false,
            .dialog = self.app.dialog != null,
            .confirmation = self.confirmation != null,
            .jobs_started = self.jobs_started,
            .jobs_reaped = self.jobs_reaped,
            .worker_limit = @as(usize, 1),
            .recheck_limit = @as(usize, 1),
            .revocation_limit = @as(usize, trust.limits.records),
            .preferences_pending = if (self.app.manager) |manager| manager.preferences_running or manager.preferences_pending != null else false,
            .permit_scope_generation = self.permit_scope.generation,
        }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_POLICY %s\n", z.ptr);
    }
};

/// Also invoked by the native policy-checks hook; no filesystem or approval.
pub fn validatePolicyContracts() !void {
    try validateRemovalScope();
    const model_digest: trust.PolicyDigest = @splat(7);
    const baseline: UserPolicy = .{ .values = .{}, .present = .{} };
    const base_digest = baseline.digest(model_digest);
    inline for (.{ "lines", "wrap", "spaces", "indent" }) |key| {
        var explicit = baseline;
        @field(explicit.present, key) = true;
        if (trust.same(base_digest, explicit.digest(model_digest))) return error.UserPresenceNotHashed;
        var changed = explicit;
        if (comptime std.mem.eql(u8, key, "indent")) changed.values.indent = 3 else @field(changed.values, key) = !@field(changed.values, key);
        if (trust.same(explicit.digest(model_digest), changed.digest(model_digest))) return error.UserValueNotHashed;
        if (changed.same(explicit)) return error.UserChangeNotDetected;
    }
    if (trust.same(base_digest, baseline.digest(@splat(8)))) return error.ModelPolicyNotHashed;
    const first: trust.Fingerprint = @splat(1);
    const alternate: trust.Fingerprint = @splat(2);
    var continuity: Continuity = .{ .workspace = @splat(0), .initial = false };
    continuity.observe(first, true);
    if (continuity.approval_required or !trust.same(continuity.expected.?, first)) return error.InitialAnchorMissing;
    continuity.observe(alternate, false);
    continuity.observe(alternate, false);
    continuity.observe(first, false);
    if (!continuity.approval_required or !trust.same(continuity.expected.?, first)) return error.RevalidationAdoptedAlternate;
    continuity.approve(alternate);
    if (continuity.approval_required or !trust.same(continuity.expected.?, alternate)) return error.ExplicitApprovalNotAdopted;
    var failed_initial: Continuity = .{ .workspace = @splat(0), .initial = false };
    failed_initial.observe(alternate, false);
    if (!failed_initial.approval_required) return error.FailedInitialRestored;
}

// Core smoke for the identity-only revoke/close race: the association query
// must work without an App/model, through queue -> active -> retry -> drain.
fn validateRemovalScope() !void {
    const token_scope = routing.Scope.init();
    var controller: Controller = .{
        .app = undefined, // No GTK or model access is allowed in this core check.
        .policy = .init(token_scope.capture().?),
        .permit_scope = token_scope,
        .user = .{ .values = .{}, .present = .{} },
    };
    const scope: trust.Fingerprint = @splat(1);
    const key: trust.Fingerprint = @splat(2);
    const unrelated: trust.Fingerprint = @splat(3);
    controller.queueRevoke(scope, key);
    if (controller.policy.state != .restricted or controller.known_len != 1 or controller.known[0].approved_revocation != 0) return error.RemovalGrantedTrust;
    if (!controller.removalPending(scope, null) or controller.removalPending(unrelated, null)) return error.QueuedRemovalLostScope;
    controller.revokes.revoke(key);
    if (!controller.removalPending(scope, key) or controller.removalPending(unrelated, key)) return error.ActiveRemovalLostScope;
    if (controller.removalPending(scope, null)) return error.DrainedRemovalBlockedApproval;
    controller.queueRevoke(null, key); // Retry after the model/identity is gone.
    if (controller.known_len != 1 or controller.unscoped_removals or !controller.removalPending(scope, null)) return error.RetriedRemovalLostScope;
    controller.revokes.revoke(key);

    // Association saturation must not make a queued or active write invisible
    // to a different owner. The conservative fallback ends when writes drain.
    for (&controller.known, 0..) |*known, i| known.* = .{ .scope = unrelated, .key = @splat(@intCast(i)) };
    controller.known_len = controller.known.len;
    controller.queueRevoke(scope, key);
    if (controller.known_len != controller.known.len or !controller.block_all or !controller.unscoped_removals) return error.RemovalAssociationLimitBypassed;
    if (!controller.removalPending(scope, null)) return error.UnscopedQueuedRemovalLost;
    controller.revokes.revoke(key);
    if (!controller.removalPending(scope, key)) return error.UnscopedActiveRemovalLost;
    if (controller.removalPending(scope, null)) return error.UnscopedDrainedRemovalBlockedApproval;
}

fn checkWidget(widget: u.W, effective: settings.Effective) !void {
    const source = u.cast(c.GtkSourceView, widget);
    const values = effective.values;
    if ((c.gtk_source_view_get_show_line_numbers(source) != 0) != values.lines) return error.LineNumbersMismatch;
    if ((c.gtk_text_view_get_wrap_mode(u.cast(c.GtkTextView, widget)) != c.GTK_WRAP_NONE) != values.wrap) return error.WrapMismatch;
    if ((c.gtk_source_view_get_insert_spaces_instead_of_tabs(source) != 0) != values.spaces) return error.SpacesMismatch;
    if (c.gtk_source_view_get_tab_width(source) != values.indent or c.gtk_source_view_get_indent_width(source) != values.indent) return error.IndentMismatch;
}
fn append(text: *std.ArrayList(u8), comptime format: []const u8, args: anytype) void {
    const part = std.fmt.allocPrint(a, format, args) catch unreachable;
    defer a.free(part);
    text.appendSlice(a, part) catch unreachable;
}
fn describeEffective(text: *std.ArrayList(u8), value: settings.Effective) void {
    append(text, "Language: {s}\n", .{value.context.language orelse "(none)"});
    inline for (.{ "lines", "wrap", "spaces", "indent" }) |key| append(text, "  {s} = {any} — {s}\n", .{ key, @field(value.values, key), @tagName(@field(value.origins, key)) });
}
fn scopeKey(m: *const model.Model) trust.Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    settings.hashField(&hash, "coral-native-local-revoke-v1");
    settings.hashField(&hash, m.manifest_path orelse "");
    for (m.roots) |root| settings.hashField(&hash, root.lexical_path);
    return hash.finalResult();
}
// Manifest root edits remain the same workspace, but change the expected key.
// Retain these anchors across close/reopen as well as replacement snapshots.
fn workspaceKey(m: *const model.Model) trust.Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    settings.hashField(&hash, "coral-native-workspace-continuity-v1");
    settings.hashField(&hash, if (m.manifest_path != null) "manifest" else "folder");
    settings.hashField(&hash, m.manifest_path orelse m.roots[0].lexical_path);
    return hash.finalResult();
}
fn inputsFor(m: *const model.Model, user: UserPolicy) !trust.Inputs {
    if (m.roots.len == 0 or m.roots.len > trust.limits.roots) return error.InvalidRoots;
    var paths: [trust.limits.roots][]const u8 = undefined;
    for (m.roots, 0..) |root, i| {
        if (root.availability != .available or root.canonical_path == null) return error.UnavailableRoot;
        paths[i] = root.lexical_path;
    }
    return trust.Inputs.init(a, .{ .manifest_path = m.manifest_path, .roots = paths[0..m.roots.len], .policy_digest = user.digest(m.policy_fingerprint) });
}
const Job = struct {
    controller: *Controller,
    kind: Kind,
    inputs: ?trust.Inputs,
    expected: ?trust.Fingerprint,
    initial_restore: bool,
    continuity_index: ?usize,
    user: UserPolicy,
    model_digest: trust.PolicyDigest,
    ticket: trust.Ticket,
    request: u64,
    model_generation: u64,
    model_token: ?routing.Token,
    scope_key: trust.Fingerprint,
    cancelled: std.atomic.Value(bool) = .init(false),
    identity: ?trust.Identity = null,
    decision: ?fs.Decision = null,
    err: ?anyerror = null,
    delay_us: u64,
    delivery_delay_us: u64,
    fail_write: bool,

    fn destroy(self: *Job) void {
        if (self.inputs) |*inputs| inputs.deinit();
        if (self.identity) |*id| id.deinit();
        a.destroy(self);
    }
    /// Reread BOTH manifest and folder policies, not merely the old digest's
    /// filesystem identity. Called before store access and again after it.
    fn fresh(self: *Job) !trust.Inputs {
        const original = self.inputs.?.value;
        var candidate = if (original.manifest_path) |path| try model.Model.fromManifest(a, path) else try model.Model.fromFolder(a, original.roots[0]);
        defer candidate.deinit();
        if (!trust.same(candidate.policy_fingerprint, self.model_digest) or !trust.same(self.user.digest(candidate.policy_fingerprint), original.policy_digest) or candidate.roots.len != original.roots.len) return error.PolicyChanged;
        for (candidate.roots, original.roots) |root, path| if (!std.mem.eql(u8, root.lexical_path, path)) return error.ScopeChanged;
        return inputsFor(&candidate, self.user);
    }
    fn perform(self: *Job) !void {
        const home = &self.controller.home.?; // Immutable until the held job is reaped.
        if (test_hooks and self.delay_us != 0) c.g_usleep(self.delay_us);
        if (self.kind == .revoke) {
            if (test_hooks and self.fail_write) return error.TestWriteFailed;
            try fs.revoke(a, home, self.expected.?);
            return;
        }
        // A revoked in-flight lookup may still discover the exact key that must
        // be removed. It cannot deliver trust, but must finish its capture.
        if (self.kind == .approve and self.cancelled.load(.acquire)) return error.Cancelled;
        var before = try self.fresh();
        defer before.deinit();
        if (self.kind == .approve) {
            if (test_hooks and self.fail_write) return error.TestWriteFailed;
            if (self.cancelled.load(.acquire)) return error.Cancelled;
            self.decision = try fs.approve(a, home, &before, self.expected.?, .user_approved);
        } else if (self.initial_restore) {
            self.decision = try fs.load(a, home, &before);
        } else if (self.expected) |expected| {
            self.decision = try fs.revalidate(a, home, &before, expected);
        } else {
            // No verified initial incarnation: capture for the confirmation UI,
            // but never consult an arbitrary stored approval as a new restore.
            var captured = try fs.capture(a, &before);
            defer captured.deinit();
            self.decision = .{ .fingerprint = captured.fingerprint, .state = .restricted };
        }
        var after = try self.fresh();
        defer after.deinit();
        self.identity = try fs.capture(a, &after);
        if (!trust.same(self.identity.?.fingerprint, self.decision.?.fingerprint)) return error.ScopeChanged;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
};
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    job.perform() catch |err| {
        job.err = err;
    };
    if (test_hooks and job.delivery_delay_us != 0) c.g_usleep(job.delivery_delay_us);
    c.g_task_return_boolean(task, 1);
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, data.?);
    const self = job.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.active == job);
    self.active = null;
    defer {
        job.destroy();
        self.jobs_reaped += 1;
        self.pump(); // Acquire the next hold BEFORE releasing this one.
        self.app.release();
    }
    if (job.kind == .revoke) {
        if (job.err) |err| {
            self.failed_revokes.approve(job.expected.?) catch {
                self.block_all = true;
            };
            self.fail(err);
            self.error_is_revoke = true;
        } else {
            self.failed_revokes.revoke(job.expected.?);
            if (self.failed_revokes.len == 0 and self.error_is_revoke) self.clearError();
            if (!self.pending) self.status = if (self.store_error != null) .failed else .restricted;
        }
        return;
    }
    const current = !self.closed and self.app.browser.watches.policyReady() and !job.cancelled.load(.acquire) and self.request == job.request and self.model_generation == job.model_generation and self.policy.accepts(job.ticket) and job.user.same(UserPolicy.capture(self.app)) and if (self.app.browser.model) |*m| m.scope.accepts(job.model_token.?) and trust.same(m.policy_fingerprint, job.model_digest) and trust.same(job.user.digest(m.policy_fingerprint), job.inputs.?.value.policy_digest) else false;
    // A stale approval must be removed on DISK, not only ignored on delivery.
    if (job.kind == .approve and (!current or job.err != null)) {
        self.block(job.scope_key);
        self.queueRevoke(job.scope_key, job.expected.?);
    }
    if (job.kind == .recheck and self.blocked.contains(job.scope_key)) {
        if (job.decision) |decision| if (decision.state == .trusted) {
            self.queueRevoke(job.scope_key, decision.fingerprint);
        };
    }
    if (!current) return;
    if (job.err) |err| {
        _ = self.policy.complete(job.ticket, @splat(0), null);
        self.fail(err);
        return;
    }
    if (self.identity) |*id| id.deinit();
    self.identity = job.identity;
    job.identity = null;
    const decision = job.decision.?;
    const continuity = &self.continuity[job.continuity_index.?];
    if (job.kind == .recheck) continuity.observe(decision.fingerprint, job.initial_restore);
    if (decision.state == .trusted) self.remember(job.scope_key, decision.fingerprint);
    const blocked = self.block_all or continuity.approval_required or self.blocked.contains(job.scope_key) or self.sharedBlocked(job.scope_key) or self.failed_revokes.contains(decision.fingerprint);
    const granted = self.policy.complete(job.ticket, decision.fingerprint, if (!self.block_all and (job.kind == .approve or !blocked)) decision.approvedKey() else null);
    if (granted and job.kind == .approve) {
        continuity.approve(decision.fingerprint);
        self.blocked.revoke(job.scope_key);
        self.failed_revokes.revoke(decision.fingerprint);
        for (self.known[0..self.known_len]) |*known| {
            if (trust.same(known.scope, job.scope_key) and trust.same(known.key, decision.fingerprint)) known.approved_revocation = self.sharedRevocation(job.scope_key);
        }
    }
    self.status = if (granted) .trusted else .restricted;
    if (self.failed_revokes.len == 0) self.clearError();
}
