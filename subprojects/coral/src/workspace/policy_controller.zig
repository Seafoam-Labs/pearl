//! Native main-context policy owner. By user request the workspace consent
//! boundary was removed: the workspace is ALWAYS trusted, with no confirmation
//! or revocation prompts and no restricted-mode gates. Workers borrow no model,
//! document or GTK state. One active identity-capture job and one coalesced
//! recheck remain so scope/generation invalidation still retires stale work.
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

/// `.restricted` is retained only so existing UI switches stay exhaustive; it
/// is never assigned. `.verifying`/`.failed` describe identity-capture health,
/// not trust: permits are issued and validated regardless of this status.
pub const Status = enum { restricted, verifying, trusted, failed };

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

pub const Controller = struct {
    app: *App,
    policy: trust.Policy,
    permit_scope: routing.Scope,
    user: UserPolicy,
    home: ?fs.StateHome = null,
    home_error: ?anyerror = null,
    status: Status = .trusted,
    store_error: ?[:0]u8 = null,
    identity: ?trust.Identity = null,
    active: ?*Job = null,
    pending: bool = false,
    closed: bool = false,
    request: u64 = 1,
    model_generation: u64 = 1,
    gate: ?trust.Permit = null,
    gate_cancelled: bool = false,
    retired_permit: ?trust.Permit = null,
    test_delay_us: u64 = 0,
    test_delivery_delay_us: u64 = 0,
    /// Injected identity-job failure. Historical name: there are no trust writes.
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
        std.debug.assert(self.active == null);
        self.permit_scope.close();
        if (self.identity) |*id| id.deinit();
        if (self.home) |*home| home.deinit();
        if (self.store_error) |text| a.free(text);
    }
    pub fn shutdown(self: *Controller) void {
        self.invalidate();
        self.closed = true;
        self.pending = false;
        self.pump(); // Refresh status once more after window close.
    }
    fn refreshStatus(self: *Controller) void {
        if (self.closed or self.app.closing or self.app.browser.closed) return;
        const text = u.fmt("Workspace: {s} · {s} · always trusted; no workspace approval required", .{ @tagName(self.policy.state), @tagName(self.status) });
        defer a.free(text);
        u.setLabel(self.app.browser.policy_status, text);
    }
    fn clearError(self: *Controller) void {
        if (self.store_error) |text| a.free(text);
        self.store_error = null;
    }
    fn fail(self: *Controller, err: anyerror) void {
        defer self.refreshStatus();
        self.status = .failed;
        self.clearError();
        self.store_error = if (err == error.WorkspaceMonitoringUnavailable)
            u.z("WorkspaceMonitoringUnavailable: root/manifest ancestry or policy watches are incomplete. Identity verification is paused; the workspace remains trusted. Check path availability and watch limits, then use Workspace: Rescan.")
        else
            u.fmt("{s}/coral/trust: {s}. The workspace remains trusted. Check state-directory ownership/permissions, then use Workspace: Rescan after root/policy changes or Recheck to retry.", .{ if (self.home) |home| home.path else "(XDG_STATE_HOME/HOME unavailable)", @errorName(err) });
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
            self.app.terminal.invalidate();
            self.app.tasks.invalidate();
        }
        defer self.refreshStatus();
        self.request = std.math.add(u64, self.request, 1) catch @panic("Policy request generation exhausted");
        self.cancelGate();
        if (self.active) |job| job.cancelled.store(true, .release);
        _ = self.policy.begin(self.token()) catch {
            self.fail(error.GenerationExhausted);
            return;
        };
        self.pending = !self.closed;
        self.status = if (self.app.browser.model != null) .verifying else .trusted;
    }
    pub fn modelChanged(self: *Controller) void {
        self.model_generation = std.math.add(u64, self.model_generation, 1) catch @panic("Policy model generation exhausted");
        self.invalidate();
        // A replacement owner gets a fresh permit token, even for the same root
        // IDs. Stale work from the previous model can never validate again.
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
    /// No consent state is written or removed anymore, so no scope cleanup can
    /// be pending. Kept for the multi-window manager protocol.
    pub fn scopeCleanupPending(self: *Controller, _: trust.Fingerprint) bool {
        _ = self;
        return false;
    }
    /// Revocation no longer exists: workspaces are always trusted. Retire
    /// outstanding permits anyway so stale work cannot continue, and inform
    /// the user instead of opening a prompt or writing removal state.
    pub fn revoke(self: *Controller) void {
        if (self.closed) return;
        self.revokeLocal();
    }
    /// Nonbroadcast half kept for the multi-window manager protocol.
    pub fn revokeLocal(self: *Controller) void {
        if (self.closed) return;
        self.invalidate();
        self.app.message("Workspace trust is always on; revocation is unavailable. Outstanding permits were retired.");
        self.refreshStatus();
    }
    /// Called from the existing GTK tick and after every reaped policy job.
    pub fn pump(self: *Controller) void {
        defer self.refreshStatus();
        if (self.active != null) return;
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
            self.status = .trusted;
            return;
        }
        self.start() catch |err| self.fail(err);
    }
    fn start(self: *Controller) !void {
        defer self.refreshStatus();
        const m = if (self.app.browser.model) |*m| m else return error.NoWorkspace;
        var inputs = try inputsFor(m, self.user);
        errdefer inputs.deinit();
        // Preserve the actionable unavailable-root diagnostic before the
        // broader monitoring gate; identity capture needs complete watches.
        if (!self.app.browser.watches.policyReady()) return error.WorkspaceMonitoringUnavailable;
        const ticket = try self.policy.begin(self.token());
        const job = try a.create(Job);
        job.* = .{
            .controller = self,
            .inputs = inputs,
            .user = self.user,
            .model_digest = m.policy_fingerprint,
            .ticket = ticket,
            .request = self.request,
            .model_generation = self.model_generation,
            .model_token = m.scope.capture(),
            .scope_key = scopeKey(m),
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
        self.status = .verifying;
        self.cancelGate();
        self.app.hold();
        const task = c.g_task_new(null, null, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    /// There is nothing to confirm: workspaces are always trusted. Kept so the
    /// existing dialog code compiles; the trust button stays insensitive.
    pub fn canConfirm(self: *Controller) bool {
        _ = self;
        return false;
    }
    /// No consent dialog exists. Explain instead of freezing a scope for approval.
    pub fn prepareConfirmation(self: *Controller) bool {
        self.app.message("Workspaces are always trusted; no approval is required.");
        return false;
    }
    pub fn confirm(self: *Controller, _: bool) void {
        _ = self;
    }
    /// Executable services obtain a permit and validate it at dispatch. The
    /// workspace is always trusted; only scope/generation staleness can reject.
    /// Service-specific user approval is still required where a service asks.
    pub fn issue(self: *Controller, capability: trust.Capability) !trust.Permit {
        return self.policy.issue(capability);
    }
    pub fn validate(self: *Controller, permit: trust.Permit, capability: trust.Capability) bool {
        return !self.closed and self.policy.validate(permit, self.token(), capability);
    }
    /// A fixture-only pending gate, not a task runner. Recheck/switch cancels it.
    pub fn fixtureGate(self: *Controller) void {
        if (!test_hooks) return;
        self.gate_cancelled = false;
        self.gate = self.issue(.tasks) catch null;
    }
    /// Native harness assertion fixture: checks actual widgets and the live
    /// capability gate without executing a service.
    pub fn fixtureCheck(self: *Controller) !void {
        if (!test_hooks) return;
        try validatePolicyContracts();
        for (self.app.views.items) |view| try checkWidget(view.widget, self.app.effectiveSettings(view.document));
        for (self.app.excerpts.items) |pane| try checkWidget(pane.editor.widget, self.app.effectiveSettings(pane.document));
        if (self.policy.state != .trusted) return error.WorkspaceNotTrusted;
        // Always trusted: a fresh permit must issue and validate for every
        // capability, even while identity verification is pending or failed.
        inline for (std.meta.tags(trust.Capability)) |capability| {
            const permit = try self.issue(capability);
            if (!self.validate(permit, capability)) return error.AlwaysTrustedPermitRejected;
        }
        if (self.identity) |id| {
            if (self.active == null and !self.pending) {
                const m = self.app.browser.model orelse return error.TrustedWithoutModel;
                if (!self.user.same(UserPolicy.capture(self.app)) or !trust.same(id.policy_digest, self.user.digest(m.policy_fingerprint))) return error.TrustedStaleUserPolicy;
            }
        }
        if (self.retired_permit) |permit| if (self.validate(permit, .tasks)) return error.StalePermitAccepted;
        if (self.gate_cancelled and self.gate != null) return error.CancelledGatePending;
    }
    pub fn describe(self: *Controller) [:0]u8 {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        append(&text, "Trust: {s} ({s})\nWorkspaces are always trusted: there is no workspace approval, confirmation, or revocation. Language servers still require their own exact configuration review before starting; Stop all sessions pauses this workspace durably until Start or Restart. Services run with your user permissions; workspace trust is NOT per-tool approval or an OS sandbox. Executables are configured only in ~/.config/coral/languages.json, never in the repository.\n\nSafe settings apply everywhere. Precedence: defaults → explicit user → workspace → folder → workspace language → folder language (GtkSource ID). Font, theme and spelling stay global. Scratch/outside-root documents use defaults and explicit user settings only.\nFolder settings require explicit Workspace: Rescan; monitoring is not recursive.\n\nState home: {s}/coral/trust (identity diagnostics only; no consent state is read or written)\n", .{ @tagName(self.policy.state), @tagName(self.status), if (self.home) |home| home.path else "(unavailable)" });
        if (self.store_error) |err| append(&text, "Error: {s}\n", .{err});
        if (self.identity) |id| append(&text, "Exact workspace fingerprint: {s}\n", .{std.fmt.bytesToHex(&id.fingerprint, .lower)});
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
        const scope = self.currentScope();
        const scope_hex = if (scope) |key| std.fmt.bytesToHex(&key, .lower) else @as([64]u8, @splat(0));
        const text = std.json.Stringify.valueAlloc(a, .{
            .scope_key = if (scope != null) @as(?[]const u8, &scope_hex) else null,
            .shared_revocation_generation = if (scope) |key| (if (self.app.manager) |manager| manager.revocationGeneration(key) else 0) else 0,
            .shared_revocation_blocked = false,
            .shared_cleanup_pending = false,
            .pending = @as(usize, @intFromBool(self.active != null)) + @intFromBool(self.pending),
            .active = if (self.active != null) @as(?[]const u8, "recheck") else null,
            .pending_recheck = self.pending,
            .queued_revokes = @as(usize, 0),
            .failed_revokes = @as(usize, 0),
            .status = self.status,
            .trust = self.policy.state,
            .fingerprint = if (self.identity != null) @as(?[]const u8, &key_hex) else null,
            .policy_fingerprint = if (self.app.browser.model != null) @as(?[]const u8, &policy_hex) else null,
            .effective_policy_fingerprint = if (self.app.browser.model != null) @as(?[]const u8, &combined_hex) else null,
            // Consent concepts are gone; keys remain for probe-schema stability.
            .expected_fingerprint = @as(?[]const u8, null),
            .approval_required = false,
            .initial_restore = false,
            .continuity_count = @as(usize, 0),
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
            .confirmation = false,
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

/// Also invoked by the native policy-checks hook; no filesystem or GTK access.
pub fn validatePolicyContracts() !void {
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
    // Always-trusted core smoke: no App/model is needed. Fresh permits validate,
    // begin() retires them, and a consumed ticket cannot complete twice.
    const token_scope = routing.Scope.init();
    var policy = trust.Policy.init(token_scope.capture().?);
    if (policy.state != .trusted) return error.WorkspaceNotTrusted;
    const permit = try policy.issue(.tasks);
    if (!policy.validate(permit, token_scope.capture().?, .tasks)) return error.AlwaysTrustedPermitRejected;
    const ticket = try policy.begin(token_scope.capture().?);
    if (policy.validate(permit, token_scope.capture().?, .tasks)) return error.StalePermitAccepted;
    if (!policy.complete(ticket)) return error.CurrentTicketRejected;
    if (policy.complete(ticket)) return error.ConsumedTicketAccepted;
    const fresh = try policy.issue(.tasks);
    if (!policy.validate(fresh, token_scope.capture().?, .tasks)) return error.AlwaysTrustedPermitRejected;
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
    inputs: trust.Inputs,
    user: UserPolicy,
    model_digest: trust.PolicyDigest,
    ticket: trust.Ticket,
    request: u64,
    model_generation: u64,
    model_token: ?routing.Token,
    scope_key: trust.Fingerprint,
    cancelled: std.atomic.Value(bool) = .init(false),
    identity: ?trust.Identity = null,
    err: ?anyerror = null,
    delay_us: u64,
    delivery_delay_us: u64,
    fail_write: bool,

    fn destroy(self: *Job) void {
        self.inputs.deinit();
        if (self.identity) |*id| id.deinit();
        a.destroy(self);
    }
    /// Reread BOTH manifest and folder policies, not merely the old digest's
    /// filesystem identity. Called before capture and again after it.
    fn fresh(self: *Job) !trust.Inputs {
        const original = self.inputs.value;
        var candidate = if (original.manifest_path) |path| try model.Model.fromManifest(a, path) else try model.Model.fromFolder(a, original.roots[0]);
        defer candidate.deinit();
        if (!trust.same(candidate.policy_fingerprint, self.model_digest) or !trust.same(self.user.digest(candidate.policy_fingerprint), original.policy_digest) or candidate.roots.len != original.roots.len) return error.PolicyChanged;
        for (candidate.roots, original.roots) |root, path| if (!std.mem.eql(u8, root.lexical_path, path)) return error.ScopeChanged;
        return inputsFor(&candidate, self.user);
    }
    fn perform(self: *Job) !void {
        if (test_hooks and self.delay_us != 0) c.g_usleep(self.delay_us);
        if (test_hooks and self.fail_write) return error.TestWriteFailed;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        var before = try self.fresh();
        defer before.deinit();
        var first = try fs.capture(a, &before);
        defer first.deinit();
        var after = try self.fresh();
        defer after.deinit();
        self.identity = try fs.capture(a, &after);
        if (!trust.same(first.fingerprint, self.identity.?.fingerprint)) return error.ScopeChanged;
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
    const current = !self.closed and self.app.browser.watches.policyReady() and !job.cancelled.load(.acquire) and self.request == job.request and self.model_generation == job.model_generation and self.policy.accepts(job.ticket) and job.user.same(UserPolicy.capture(self.app)) and if (self.app.browser.model) |*m| m.scope.accepts(job.model_token.?) and trust.same(m.policy_fingerprint, job.model_digest) and trust.same(job.user.digest(m.policy_fingerprint), job.inputs.value.policy_digest) else false;
    if (!current) return;
    if (job.err) |err| {
        _ = self.policy.complete(job.ticket);
        self.fail(err);
        return;
    }
    if (self.identity) |*id| id.deinit();
    self.identity = job.identity;
    job.identity = null;
    _ = self.policy.complete(job.ticket);
    self.status = .trusted;
    self.clearError();
}
