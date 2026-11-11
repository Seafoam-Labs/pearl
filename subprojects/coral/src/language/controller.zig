//! Window-owned native language workflows. Trust grants execution, not a sandbox.
//! Every process holds its App until the client reports transport reap completion.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const Document = @import("../document.zig").Document;
const client = @import("client.zig");
const config = @import("config.zig");
const f = @import("features.zig");
const p = @import("protocol.zig");
const positions = @import("positions.zig");
const uri = @import("uri.zig");
const edits = @import("edits.zig");
const decorations = @import("decorations.zig");
const resources = @import("resource_controller.zig");
const file_operations = @import("file_operations.zig");
const operations = @import("../workspace/operations_controller.zig");
const transactions = @import("../editor/transactions.zig");
const trust = @import("../workspace/trust.zig");
const RootId = @import("../workspace/model.zig").RootId;
const Value = std.json.Value;
const UI = @import("ui.zig").UI;
extern fn gtk_source_language_get_id(language: *c.GtkSourceLanguage) [*c]const u8;
pub const max_sessions = 8;
// Input sends are atomic: a maximum 4 MiB JSON body plus framing needs the
// next power of two. Output is streamed into the bounded protocol framer.
// Eight sessions reserve at most 96 MiB of queues, separately from the client's
// 8 MiB/session document snapshots, framing/event buffers, editor storage and
// transport worker stacks (16 MiB/thread with Zig 0.17.1).
pub const transport_input_bytes = 8 * 1024 * 1024;
pub const transport_output_bytes = 4 * 1024 * 1024;
pub const Action = enum { completion, hover, signature, definition, declaration, type_definition, implementation, references, document_symbols, workspace_symbols, formatting, range_formatting, rename, code_actions, semantic_tokens, inlay_hints, code_lenses, document_links };
const Synced = struct {
    id: u64,
    uri: []u8,
    revision: u64,
    version: i32,
    diagnostics: ?f.Owned(f.Diagnostics) = null,
    verified: bool = false,
    diagnostic_charge: usize = 0,
    tokens: ?f.Owned(f.SemanticTokens) = null,
    semantic_revision: ?u64 = null,
    fn deinit(self: *Synced) void {
        a.free(self.uri);
        if (self.diagnostics) |*d| d.deinit();
        if (self.tokens) |*t| t.deinit();
    }
};
const Session = struct {
    pipe: *client.Client,
    root: RootId,
    path: []u8,
    language: []u8,
    digest: config.Digest,
    config_binding: config.Binding,
    permit: trust.Permit,
    presentation_retired: bool = false,
    sync_failure: ?anyerror = null,
    docs: std.ArrayList(Synced) = .empty,
    version: i32 = 0,
    cursor: usize = 0,
    restart: bool = false,
    fn doc(self: *Session, id: u64) ?*Synced {
        for (self.docs.items) |*d| if (d.id == id) return d;
        return null;
    }
};
const Pending = struct { session: u64, id: i64, action: Action, context: client.Context, revision: u64, cursor: usize, kind: enum { feature, lens, link, action, symbol, execute } = .feature };
const Location = struct { uri: []const u8, range: positions.Range, session: ?u64 = null, document: ?u64 = null, revision: ?u64 = null };
const Row = struct { label: []const u8, after_command: ?Value = null, payload: union(enum) { none, location: Location, edit: Value, command: Value, link: []const u8, resolve_lens: Value, resolve_link: Value, resolve_action: Value, resolve_symbol: Value } = .none };
const Mode = enum { info, start, picker, rename, workspace_query, review_loading, review, resource, command, external };
const ReviewTarget = struct { path: []const u8, id: ?u64, revision: ?u64, accepted: bool = false, requested: bool = false };
const ReviewLoad = struct { value: Value, targets: []ReviewTarget, deadline: i64 };
const Navigation = struct { path: []u8, location: Location, encoding: positions.Encoding, session: u64, group: u64, source: client.Context, source_revision: u64, accepted: bool = false, revision: ?u64 = null, deadline: i64 };
const caps =
    \\{"window":{"workDoneProgress":true},"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"resourceOperations":["create","rename","delete"],"failureHandling":"textOnlyTransactional","changeAnnotationSupport":{"groupsOnLabel":true}},"fileOperations":{"dynamicRegistration":false,"didCreate":true,"didRename":true,"didDelete":true},"symbol":{"dynamicRegistration":false,"resolveSupport":{"properties":["location.range"]}}},"textDocument":{"completion":{"completionItem":{"snippetSupport":false,"insertReplaceSupport":true,"documentationFormat":["plaintext"]}},"hover":{"contentFormat":["plaintext"]},"signatureHelp":{"signatureInformation":{"documentationFormat":["plaintext"],"parameterInformation":{"labelOffsetSupport":true}}},"definition":{"linkSupport":true},"declaration":{"linkSupport":true},"typeDefinition":{"linkSupport":true},"implementation":{"linkSupport":true},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true},"codeAction":{"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","source"]}},"disabledSupport":true,"dataSupport":true,"resolveSupport":{"properties":["edit","command"]}},"documentLink":{"tooltipSupport":true},"publishDiagnostics":{"dataSupport":true},"semanticTokens":{"requests":{"full":{"delta":true}},"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":false},"inlayHint":{"dynamicRegistration":false}}}
;
pub const Controller = struct {
    app: *App,
    sessions: [max_sessions]?*Session = @splat(null),
    timer: c_uint = 0,
    pending: ?Pending = null,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    ui: UI = undefined,
    mode: Mode = .info,
    screen_session: ?u64 = null,
    screen_context: client.Context = .{},
    screen_revision: u64 = 0,
    screen_cursor: usize = 0,
    plan: ?edits.Plan = null,
    resource: ?*resources.Request = null,
    file_notifications: u64 = 0,
    server_token: ?u64 = null,
    server_deadline: i64 = 0,
    review_load: ?ReviewLoad = null,
    config_monitors: [4]?*c.GFileMonitor = @splat(null),
    config_monitors_dirty: bool = false,
    config_generation: u64 = 0,
    screen_generation: u64 = 0,
    config_job: ?*ConfigJob = null,
    config_queued: ?*ConfigJob = null,
    next_config_poll: i64 = 0,
    approval_dispatch: bool = false,
    resource_review_shown: bool = false,
    test_config_poll_disabled: bool = false,
    after_command: ?Value = null,
    command_value: Value = .null,
    external_url: []const u8 = "",
    start_root: ?RootId = null,
    start_language: []const u8 = "",
    start_binding: ?config.Binding = null,
    scratch: ?[:0]u8 = null,
    navigation: ?Navigation = null,
    status: [:0]u8,
    progress: [:0]u8,
    pub fn init(app: *App) Controller {
        return .{ .app = app, .ui = .{ .context = app, .respond = &answered }, .arena = std.heap.ArenaAllocator.init(a), .status = u.z("Stopped — explicit trusted Language: Start required"), .progress = u.z("") };
    }
    fn allocator(self: *Controller) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn bindUI(self: *Controller) void {
        self.ui = .{ .context = self.app, .respond = &answered };
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.status);
        self.status = u.z(prefixText(text, 8192));
        if (!self.app.closing) {
            self.app.message(self.status);
            if (self.app.chrome) |*chrome| u.setLabel(chrome.language_label, self.summary());
        }
    }
    fn failure(self: *Controller, err: anyerror) void {
        const text = u.fmt("Language: {s}", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.resource == null and self.config_job == null and self.config_queued == null);
        for (self.sessions) |s| std.debug.assert(s == null);
        self.clearScreen();
        self.clearNavigation();
        self.clearConfigMonitors();
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.arena.deinit();
        if (self.scratch) |text| a.free(text);
        a.free(self.status);
        a.free(self.progress);
    }
    fn clearNavigation(self: *Controller) void {
        if (self.navigation) |nav| {
            a.free(nav.path);
            a.free(nav.location.uri);
        }
        self.navigation = null;
    }
    fn clearScreen(self: *Controller) void {
        self.screen_generation += 1;
        if (self.config_queued) |job| job.destroy();
        self.config_queued = null;
        if (self.resource) |request_resource| request_resource.cancel();
        self.ui.close();
        if (self.pending) |pending| if (self.session(pending.session)) |s| s.pipe.cancel(pending.id) catch {};
        self.pending = null;
        self.review_load = null;
        if (self.plan) |*plan| plan.deinit();
        self.plan = null;
        if (self.server_token) |token| if (self.screenSession()) |s| self.replyEdit(s, token, false, "Review dismissed");
        self.server_token = null;
        self.after_command = null;
        self.rows = .empty;
        _ = self.arena.reset(.free_all);
        self.screen_session = null;
        self.mode = .info;
    }
    fn session(self: *Controller, id: u64) ?*Session {
        for (self.sessions) |s| if (s) |v| if (v.pipe.session == id) return v;
        return null;
    }
    fn screenSession(self: *Controller) ?*Session {
        return self.session(self.screen_session orelse return null);
    }
    fn valid(self: *Controller, s: *Session) bool {
        return !self.app.closing and self.app.workspace_policy.validate(s.permit, .lsp);
    }
    pub fn invalidate(self: *Controller) void {
        self.config_generation += 1;
        self.clearScreen();
        self.clearNavigation();
        self.pending = null;
        for (self.sessions) |slot| if (slot) |s| {
            s.restart = false;
            self.stopSession(s);
        };
    }
    fn stopSession(self: *Controller, s: *Session) void {
        s.pipe.stop() catch {};
        s.pipe.pipe.stop();
        self.retirePresentation(s);
    }
    fn clearPresentation(self: *Controller, synced: *Synced) void {
        if (self.app.documents.get(synced.id)) |doc| {
            decorations.clear(doc, false);
            decorations.clear(doc, true);
        }
        if (synced.diagnostics) |*diag| diag.deinit();
        synced.diagnostics = null;
        synced.verified = false;
        synced.diagnostic_charge = 0;
        synced.semantic_revision = null;
    }
    fn disposeSynced(self: *Controller, synced: *Synced) void {
        self.clearPresentation(synced);
        synced.deinit();
    }
    fn retirePresentation(self: *Controller, s: *Session) void {
        if (s.presentation_retired) return;
        s.presentation_retired = true;
        for (s.docs.items) |*synced| self.clearPresentation(synced);
    }
    pub fn stop(self: *Controller) void {
        self.invalidate();
        self.message("Language sessions stopping; no automatic restart.");
    }
    pub fn restart(self: *Controller) void {
        const s = self.selectedSession() catch |err| {
            if (err == error.LanguageServerNotStarted) self.startDialog() else self.failure(err);
            return;
        };
        self.clearScreen();
        self.pending = null;
        self.clearNavigation();
        self.stopSession(s);
        s.restart = true;
        self.message("Restart requested; waiting for the old process to be reaped.");
    }
    fn language(d: *Document) ?[]const u8 {
        if (d.language) |lang| {
            const id = gtk_source_language_get_id(lang);
            if (id != null) return std.mem.span(id);
        }
        return null;
    }
    fn rootFor(self: *Controller, d: *Document) !RootId {
        const m = self.app.browser.model orelse return error.NoWorkspace;
        return (try m.ownerOfCanonicalPath(d.path orelse return error.SaveDocumentFirst)) orelse error.DocumentOutsideWorkspace;
    }
    fn activeSession(self: *Controller) !*Session {
        const s = try self.selectedSession();
        if (s.pipe.state != .ready) return error.LanguageServerNotReady;
        return s;
    }
    fn selectedSession(self: *Controller) !*Session {
        const d = self.app.active() orelse return error.NoDocument;
        const root = try self.rootFor(d);
        const lang = language(d) orelse return error.NoDocumentLanguage;
        for (self.sessions) |slot| if (slot) |s| if (s.root == root and std.mem.eql(u8, s.language, lang)) {
            if (!self.valid(s)) return error.Restricted;
            return s;
        };
        return error.LanguageServerNotStarted;
    }
    pub fn startDialog(self: *Controller) void {
        self.prepareStart() catch |err| self.failure(err);
    }
    fn clearConfigMonitors(self: *Controller) void {
        for (&self.config_monitors) |*slot| if (slot.*) |monitor| {
            _ = c.g_file_monitor_cancel(monitor);
            _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(monitor);
            slot.* = null;
        };
    }
    fn rearmConfigMonitors(self: *Controller) void {
        self.clearConfigMonitors();
        self.config_monitors_dirty = false;
        if (self.app.closing) return;
        const home = c.g_get_home_dir();
        if (home == null) return;
        const suffixes = [_][]const u8{ "", "/.config", "/.config/coral", "/.config/coral/languages.json" };
        for (suffixes, 0..) |suffix, i| {
            const path = u.fmt("{s}{s}", .{ std.mem.span(home), suffix });
            defer a.free(path);
            const file = c.g_file_new_for_path(path).?;
            defer c.g_object_unref(file);
            const monitor = if (i == 3) c.g_file_monitor_file(file, c.G_FILE_MONITOR_WATCH_MOVES, null, null) else c.g_file_monitor_directory(file, c.G_FILE_MONITOR_WATCH_MOVES, null, null);
            self.config_monitors[i] = monitor;
            if (monitor) |value| u.connect(value, "changed", &configurationChanged, self);
        }
    }
    fn queueConfig(self: *Controller, kind: ConfigKind, root: ?RootId, lang: []const u8, expected: ?config.Binding) !void {
        if (self.app.closing) return error.Closing;
        if (self.config_queued != null) return error.ConfigurationCheckPending;
        const job = try a.create(ConfigJob);
        errdefer a.destroy(job);
        job.* = .{ .owner = self, .kind = kind, .root = root, .language = try a.dupe(u8, lang), .expected = expected, .generation = self.config_generation, .screen = self.screen_generation, .mode = self.mode, .session = if (self.resource) |r| r.session else self.screen_session };
        if (self.config_job != null) self.config_queued = job else self.dispatchConfig(job);
        if (kind != .poll) self.message("Checking current language configuration…");
    }
    fn dispatchConfig(self: *Controller, job: *ConfigJob) void {
        std.debug.assert(self.config_job == null);
        self.config_job = job;
        job.deadline = c.g_get_monotonic_time() + 5_000_000;
        self.next_config_poll = c.g_get_monotonic_time() + 500_000;
        self.app.hold();
        if (self.timer == 0) self.timer = c.g_timeout_add(20, &tick, self);
        const task = c.g_task_new(null, null, &configDone, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &configWorker);
        c.g_object_unref(task);
    }
    fn configReady(self: *Controller, job: *ConfigJob) !void {
        const cfg = &job.result.?;
        // The same binding check gates periodic checks, text edits, commands and
        // resource approvals. Monitors are only a prompt invalidation mechanism.
        for (self.sessions) |slot| if (slot) |s| if (!s.config_binding.same(cfg.binding())) return error.LanguageConfigChanged;
        switch (job.kind) {
            .poll => {},
            .start => try self.showStart(cfg, job.root.?, job.language),
            .launch => try self.launch(cfg, job.root.?, job.language, job.expected),
            .approve => {
                const s = self.session(job.session orelse return error.StaleSession) orelse return error.StaleSession;
                if (!self.valid(s) or self.mode != job.mode) return error.StaleLanguageApproval;
                if (job.mode == .resource) {
                    if (!self.resourceCurrent(self.resource orelse return error.StaleLanguageApproval)) return error.StaleResourceAuthorization;
                } else try self.checkScreen(s);
                self.approval_dispatch = true;
                defer self.approval_dispatch = false;
                switch (job.mode) {
                    .review => try self.apply(),
                    .command => try self.executeCommand(s),
                    .resource => self.app.workspace_operations.respond(true),
                    .external => {
                        const target = u.z(self.external_url);
                        defer a.free(target);
                        if (c.g_app_info_launch_default_for_uri(target, null, null) == 0) return error.ExternalLinkLaunchFailed;
                    },
                    else => return error.StaleLanguageApproval,
                }
            },
        }
    }
    fn showResourceReview(self: *Controller) void {
        const request_resource = self.resource orelse return;
        if (self.resource_review_shown or request_resource.cancelled or self.app.workspace_operations.state != .confirming) return;
        // Keep Explorer's prepared descriptors and final admission/barrier, but
        // route approval through the same asynchronous config guard as text edits.
        if (self.app.workspace_operations.dialog) |dialog| c.gtk_widget_set_visible(dialog, 0);
        self.resource_review_shown = true;
        self.bindUI();
        self.mode = .resource;
        self.ui.show(self.app, "Language: Confirm resource operation", request_resource.review, &.{}, false, if (request_resource.kind == .delete) "Delete permanently" else "Apply filesystem operation");
    }
    fn prepareStart(self: *Controller) !void {
        _ = try self.app.workspace_policy.issue(.lsp);
        const d = self.app.active() orelse return error.NoDocument;
        const root = try self.rootFor(d);
        const lang = language(d) orelse return error.NoDocumentLanguage;
        self.clearScreen();
        try self.queueConfig(.start, root, lang, null);
    }
    fn showStart(self: *Controller, cfg: *const config.Config, root: RootId, lang: []const u8) !void {
        _ = try self.app.workspace_policy.issue(.lsp);
        const server = cfg.find(lang) orelse return error.LanguageNotConfigured;
        self.bindUI();
        self.mode = .start;
        self.start_root = root;
        self.start_language = try self.allocator().dupe(u8, lang);
        self.start_binding = cfg.binding();
        const m = self.app.browser.model.?;
        const path = m.rootById(root).?.canonical_path orelse return error.RootUnavailable;
        const args = try std.json.Stringify.valueAlloc(self.allocator(), server.argv, .{ .escape_unicode = true });
        const environment = try std.json.Stringify.valueAlloc(self.allocator(), server.env, .{ .escape_unicode = true });
        const text = try std.fmt.allocPrint(self.allocator(), "Start {s} for {s}?\nExecutable/argv: {s}\nEnvironment allowlist: {s}\nWorking directory: {s}\n\nThis process has your user permissions. Workspace trust is NOT an OS sandbox. It can read/write files and access the network. No installation, shell expansion, or repository executable configuration is used. Nothing starts automatically.", .{ lang, path, args, environment, path });
        self.ui.show(self.app, "Language: Start", text, &.{}, false, "Start process");
    }
    fn launch(self: *Controller, cfg: *const config.Config, root: RootId, lang: []const u8, expected: ?config.Binding) !void {
        const permit = try self.app.workspace_policy.issue(.lsp);
        if (expected) |binding| if (!binding.same(cfg.binding())) return error.LanguageConfigChangedReviewAgain;
        const server = cfg.find(lang) orelse return error.LanguageNotConfigured;
        const m = self.app.browser.model orelse return error.NoWorkspace;
        const path = (m.rootById(root) orelse return error.RootUnavailable).canonical_path orelse return error.RootUnavailable;
        var target: ?*?*Session = null;
        for (&self.sessions) |*slot| {
            if (slot.*) |s| {
                if (s.root == root and std.mem.eql(u8, s.language, lang)) return error.SessionAlreadyExists;
            } else if (target == null) {
                target = slot;
            }
        }
        const slot = target orelse return error.SessionLimit;
        const s = try a.create(Session);
        errdefer a.destroy(s);
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        const owned_language = try a.dupe(u8, lang);
        errdefer a.free(owned_language);
        if (!self.app.workspace_policy.validate(permit, .lsp)) return error.Restricted;
        const pipe = try client.Client.init(a, .{ .root = path, .language_id = lang, .transport = .{ .authorization = .approved, .argv = server.argv, .cwd = path, .environment = server.env, .input_limit = transport_input_bytes, .output_limit = transport_output_bytes }, .additional_capabilities = caps, .unversioned_diagnostics = .surface_unverified });
        s.* = .{ .pipe = pipe, .root = root, .path = owned_path, .language = owned_language, .digest = cfg.digest, .config_binding = cfg.binding(), .permit = permit };
        slot.* = s;
        self.rearmConfigMonitors();
        self.app.hold();
        if (self.timer == 0) self.timer = c.g_timeout_add(20, &tick, self);
        self.message("Language server starting…");
    }
    pub fn changed(self: *Controller, d: *Document) void {
        for (self.sessions) |slot| if (slot) |s| if (s.doc(d.id)) |synced| {
            if (synced.revision != d.revision) {
                self.clearPresentation(synced);
            }
        };
    }
    pub fn closed(self: *Controller, d: *Document) void {
        for (self.sessions) |slot| if (slot) |s| {
            var i: usize = 0;
            while (i < s.docs.items.len) {
                if (s.docs.items[i].id == d.id) {
                    var old = s.docs.orderedRemove(i);
                    s.pipe.close(old.uri) catch {};
                    self.disposeSynced(&old);
                } else i += 1;
            }
        };
    }
    pub fn documentSaved(self: *Controller, d: *Document, revision: u64) void {
        if (revision != d.revision) return;
        for (self.sessions) |slot| if (slot) |s| if (self.valid(s) and s.pipe.state == .ready) {
            self.sync(s, d) catch |err| {
                self.failure(err);
                continue;
            };
            if (s.doc(d.id)) |synced| s.pipe.save(synced.uri) catch |err| {
                self.failSync(s, err);
                self.failure(err);
            };
        };
    }
    fn failSync(self: *Controller, s: *Session, err: anyerror) void {
        if (s.sync_failure == null) s.sync_failure = err;
        s.restart = false;
        self.stopSession(s);
    }
    fn sync(self: *Controller, s: *Session, d: *Document) !void {
        if (s.pipe.state != .ready) return error.LanguageServerNotReady;
        // A rejected snapshot is not retryable every 20ms: all entry points
        // (poll, save, feature requests, edit application) retire this session.
        self.syncDocument(s, d) catch |err| {
            self.failSync(s, err);
            return err;
        };
    }
    fn syncDocument(self: *Controller, s: *Session, d: *Document) !void {
        if (d.loading or d.pending != null) return;
        const belongs = (self.rootFor(d) catch null) == s.root and if (language(d)) |lang| std.mem.eql(u8, lang, s.language) else false;
        const path = d.path orelse {
            self.closed(d);
            return;
        };
        const document_uri = try uri.fromPath(a, path);
        defer a.free(document_uri);
        if (s.doc(d.id)) |old| {
            if (!belongs or !std.mem.eql(u8, old.uri, document_uri)) {
                self.closed(d);
                if (!belongs) return;
            }
        } else if (!belongs) return;
        if (s.doc(d.id)) |old| if (old.revision == d.revision) return;
        if (c.gtk_text_buffer_get_char_count(d.buffer) > client.max_document_bytes / 4) return error.DocumentTooLarge;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const version = std.math.add(i32, s.version, 1) catch return error.VersionExhausted;
        if (s.doc(d.id)) |old| {
            _ = try s.pipe.change(document_uri, version, text);
            old.revision = d.revision;
            old.version = version;
        } else {
            if (s.docs.items.len >= client.max_documents) return error.DocumentLimit;
            try s.docs.ensureUnusedCapacity(a, 1);
            const owned = try a.dupe(u8, document_uri);
            errdefer a.free(owned);
            _ = try s.pipe.open(document_uri, d.id, version, text);
            s.docs.appendAssumeCapacity(.{ .id = d.id, .uri = owned, .revision = d.revision, .version = version });
        }
        s.version = version;
    }
    fn pump(self: *Controller) void {
        if (self.config_monitors_dirty) self.rearmConfigMonitors();
        if (self.config_job) |job| {
            if (!job.timed_out and c.g_get_monotonic_time() >= job.deadline) {
                job.timed_out = true;
                self.invalidate();
                self.failure(error.LanguageConfigCheckTimedOut);
            }
        } else if (self.config_queued == null and !self.app.closing and !(@import("build_options").test_hooks and self.test_config_poll_disabled) and c.g_get_monotonic_time() >= self.next_config_poll) {
            for (self.sessions) |slot| if (slot) |s| if (s.pipe.state == .ready) {
                self.queueConfig(.poll, null, "", null) catch |err| self.failure(err);
                break;
            };
        }
        if (self.resource) |request_resource| if (!request_resource.cancelled and !self.resourceCurrent(request_resource)) request_resource.cancel();
        for (&self.sessions) |*slot| if (slot.*) |s| {
            if (!self.valid(s)) {
                s.restart = false;
                self.stopSession(s);
            }
            if (s.pipe.state == .ready) {
                var stale: usize = 0;
                while (stale < s.docs.items.len) {
                    if (self.app.documents.get(s.docs.items[stale].id) == null) {
                        var old = s.docs.orderedRemove(stale);
                        s.pipe.close(old.uri) catch {};
                        self.disposeSynced(&old);
                    } else stale += 1;
                }
                const docs = self.app.documents.entries.items;
                for (0..@min(docs.len, 4)) |_| {
                    if (s.cursor >= docs.len) s.cursor = 0;
                    self.sync(s, docs[s.cursor]) catch |err| {
                        self.failure(err);
                        break;
                    };
                    s.cursor += 1;
                }
            }
            s.pipe.tick(@intCast(@divTrunc(c.g_get_monotonic_time(), 1000))) catch |err| self.failure(err);
            if (s.pipe.state == .crashed or s.pipe.state == .stopping or s.pipe.state == .stopped) self.retirePresentation(s);
            for (0..8) |_| {
                var event = s.pipe.nextEvent() orelse break;
                defer event.deinit();
                self.handleEvent(s, &event) catch |err| self.failure(err);
            }
            if (s.pipe.isDrained()) {
                const restart_requested = s.restart and self.valid(s);
                const root = s.root;
                const lang = u.z(s.language);
                defer a.free(lang);
                const binding = s.config_binding;
                if (self.screen_session == s.pipe.session) self.clearScreen();
                if (self.pending) |pending| if (pending.session == s.pipe.session) {
                    self.pending = null;
                };
                for (s.docs.items) |*doc| self.disposeSynced(doc);
                s.docs.deinit(a);
                s.pipe.destroy() catch unreachable;
                a.free(s.path);
                a.free(s.language);
                a.destroy(s);
                slot.* = null;
                self.app.release();
                if (restart_requested) self.queueConfig(.launch, root, lang, binding) catch |err| self.failure(err);
            }
        };
        self.showResourceReview();
        if (self.server_token != null and !self.serverReviewCurrent()) {
            self.clearScreen();
            self.message("Language server cancelled or expired the edit review. No changes applied.");
        }
        self.finishReviewLoad() catch |err| {
            self.review_load = null;
            if (self.server_token) |token| {
                if (self.screenSession()) |s| self.replyEdit(s, token, false, @errorName(err));
                self.server_token = null;
            }
            self.failure(err);
        };
        self.finishNavigation() catch |err| {
            self.clearNavigation();
            self.failure(err);
        };
    }
    fn handleEvent(self: *Controller, s: *Session, e: *client.Event) !void {
        switch (e.kind) {
            .ready => self.message("Language server ready."),
            .finished => {
                self.retirePresentation(s);
                const result = e.result.?;
                const reason: []const u8 = if (result.spawn_errno == 2) " — configured executable not found" else if (result.spawn_errno == 13) " — executable permission denied" else "";
                const text = u.fmt("Language server {s}{s}; reaped={}; spawn errno={d}; stderr bytes discarded: {d}; synchronization failure: {s}", .{ @tagName(result.outcome), reason, result.reaped, result.spawn_errno, result.stderr.bytes, if (s.sync_failure) |err| @errorName(err) else "none" });
                defer a.free(text);
                self.message(text);
            },
            .status => if (e.failure) |err| self.failure(err) else {
                const params = p.field(e.value(), "params") orelse .null;
                if (p.string(p.field(params, "message") orelse .null)) |raw| {
                    const plain = try f.plainText(a, prefixText(raw, 4096));
                    defer a.free(plain);
                    const notice = u.fmt("Language server: {s}", .{plain});
                    defer a.free(notice);
                    self.message(notice);
                }
            },
            .progress, .notification => {
                const raw = try std.json.Stringify.valueAlloc(a, p.field(e.value(), "params") orelse .null, .{});
                defer a.free(raw);
                a.free(self.progress);
                self.progress = u.z(prefixText(raw, 4096));
            },
            .diagnostics => {
                const d = self.app.documents.get(e.context.doc_id orelse return) orelse return;
                const synced = s.doc(d.id) orelse return;
                if (synced.revision != d.revision or !self.valid(s) or s.pipe.state != .ready or s.presentation_retired) return;
                var retained: usize = 0;
                for (self.sessions) |slot| if (slot) |owner_session| for (owner_session.docs.items) |document| if (document.diagnostics != null and !(owner_session == s and document.id == d.id)) {
                    retained += document.diagnostic_charge;
                };
                if (e.charge > 256 * 1024 or e.charge > 8 * 1024 * 1024 -| retained) return error.DiagnosticsDisplayBudgetExceeded;
                const text = u.bufferText(d.buffer);
                defer a.free(text);
                var decoded = try f.parse(.diagnostics, a, try f.required(e.value(), "params"), text, s.pipe.capabilities.encoding);
                errdefer decoded.deinit();
                if (synced.diagnostics) |*old| old.deinit();
                synced.diagnostics = decoded;
                synced.verified = e.verified;
                synced.diagnostic_charge = e.charge;
                try decorations.diagnostics(d, text, decoded.value.items);
            },
            .response => {
                const pending = self.pending orelse return;
                if (pending.id != e.id or pending.session != s.pipe.session) return;
                self.pending = null;
                if (!self.valid(s) or s.presentation_retired or !s.pipe.isCurrent(pending.context)) return error.StaleLanguageResponse;
                if (pending.context.doc_id) |id| if ((self.app.documents.get(id) orelse return error.DocumentClosed).revision != pending.revision) return error.StaleLanguageResponse;
                if (p.field(e.value(), "error")) |err| {
                    const raw = try std.json.Stringify.valueAlloc(a, err, .{});
                    defer a.free(raw);
                    self.message(raw);
                    return;
                }
                const result = p.field(e.value(), "result") orelse .null;
                self.message("Language response received.");
                if (pending.kind == .feature) try self.present(s, pending, result) else try self.presentResolved(s, pending, result);
            },
            .cancelled, .timed_out => if (self.pending) |pending| {
                if (pending.id == e.id and pending.session == s.pipe.session) {
                    self.pending = null;
                    self.message(if (e.kind == .timed_out) "Language request timed out." else "Language request cancelled by document change.");
                }
            },
            .server_request => {
                const token = e.token.?;
                if (std.mem.eql(u8, e.method, "workspace/applyEdit")) {
                    const busy_request = if (self.pending) |pending| pending.kind != .execute else false;
                    if (!self.valid(s) or self.ui.window != null or busy_request or self.review_load != null or self.resource != null or self.app.editingFrozen()) {
                        self.replyEdit(s, token, false, "Client busy or restricted");
                        return;
                    }
                    const value = f.required(try f.required(e.value(), "params"), "edit") catch {
                        self.replyEdit(s, token, false, "Missing edit");
                        return;
                    };
                    // executeCommand may await this applyEdit before responding.
                    // Do not cancel that request or reject its nested edit as busy.
                    const executing = self.pending;
                    self.pending = null;
                    self.clearScreen();
                    self.pending = executing;
                    self.screen_session = s.pipe.session;
                    self.screen_context = .{ .session = s.pipe.session };
                    self.server_deadline = c.g_get_monotonic_time() + 25_000_000;
                    self.review(s, value, token) catch |err| {
                        self.replyEdit(s, token, false, @errorName(err));
                        return err;
                    };
                } else try s.pipe.reject(token, -32601, "Native client does not implement this server request");
            },
        }
    }
    pub fn request(self: *Controller, action: Action) void {
        self.begin(action, "") catch |err| self.failure(err);
    }
    fn begin(self: *Controller, action: Action, input: []const u8) !void {
        if (self.resource != null) return error.ResourceOperationPending;
        if (self.app.activeView() == null) return error.ExcerptLanguagePositionUnavailableOpenCanonicalView;
        const s = try self.activeSession();
        const d = self.app.active().?;
        try self.sync(s, d);
        const synced = s.doc(d.id) orelse return error.DocumentNotSynchronized;
        const provider = providerFor(action);
        if (!s.pipe.capabilities.supports(provider)) {
            const notice = u.fmt("Language: {s} is unavailable; server does not advertise {s}.", .{ @tagName(action), provider });
            defer a.free(notice);
            self.message(notice);
            return;
        }
        if (action == .semantic_tokens) {
            const options = p.field(s.pipe.capabilities.options, provider) orelse .null;
            const full = p.field(options, "full") orelse .null;
            if (full != .object and !(full == .bool and full.bool)) return error.ServerDoesNotSupportFullSemanticTokens;
        }
        if (self.pending) |pending| {
            if (self.session(pending.session)) |old| old.pipe.cancel(pending.id) catch {};
            self.pending = null;
        }
        self.clearScreen();
        self.bindUI();
        self.screen_session = s.pipe.session;
        self.screen_context = s.pipe.contextFor(synced.uri).?;
        self.screen_revision = d.revision;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const view = self.app.activeView().?;
        var cursor_iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(view.buffer, &cursor_iter, c.gtk_text_buffer_get_insert(view.buffer));
        const cursor = try byteAt(text, c.gtk_text_iter_get_offset(&cursor_iter));
        self.screen_cursor = cursor;
        if ((action == .rename or action == .workspace_symbols) and input.len == 0) {
            self.mode = if (action == .rename) .rename else .workspace_query;
            self.ui.show(self.app, if (action == .rename) "Language: Rename" else "Workspace symbols", if (action == .rename) "New name (changes will be reviewed, never automatically saved):" else "Search all symbols in this root:", &.{}, true, "Request");
            return;
        }
        const alloc = self.allocator();
        var params = object(alloc);
        try put(alloc, &params, "textDocument", try json(alloc, .{ .uri = synced.uri }));
        try put(alloc, &params, "position", try json(alloc, try positions.positionAt(text, cursor, s.pipe.capabilities.encoding)));
        if (action == .references) try put(alloc, &params, "context", try json(alloc, .{ .includeDeclaration = true }));
        if (action == .rename) try put(alloc, &params, "newName", .{ .string = try alloc.dupe(u8, input) });
        if (action == .workspace_symbols) {
            params = object(alloc);
            try put(alloc, &params, "query", .{ .string = try alloc.dupe(u8, input) });
        }
        if (action == .formatting or action == .range_formatting) {
            const settings = self.app.effectiveSettings(d);
            try put(alloc, &params, "options", try json(alloc, .{ .tabSize = settings.values.indent, .insertSpaces = settings.values.spaces }));
        }
        if (action == .range_formatting or action == .code_actions or action == .inlay_hints) {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            const selected = c.gtk_text_buffer_get_selection_bounds(view.buffer, &start, &end) != 0;
            const lo = if (action == .inlay_hints) 0 else if (selected) try byteAt(text, c.gtk_text_iter_get_offset(&start)) else cursor;
            const hi = if (action == .inlay_hints) text.len else if (selected) try byteAt(text, c.gtk_text_iter_get_offset(&end)) else cursor;
            if (action == .range_formatting and !selected) return error.SelectRangeFirst;
            try put(alloc, &params, "range", try json(alloc, .{ .start = try positions.positionAt(text, lo, s.pipe.capabilities.encoding), .end = try positions.positionAt(text, hi, s.pipe.capabilities.encoding) }));
            if (action == .code_actions) {
                var diagnostic_values = std.json.Array.init(alloc);
                if (synced.diagnostics) |diag| for (diag.value.items) |item| {
                    if (item.range.end < lo or item.range.start > hi) continue;
                    var value = object(alloc);
                    try put(alloc, &value, "range", try json(alloc, .{ .start = try positions.positionAt(text, item.range.start, s.pipe.capabilities.encoding), .end = try positions.positionAt(text, item.range.end, s.pipe.capabilities.encoding) }));
                    try put(alloc, &value, "message", .{ .string = item.message });
                    if (item.severity != .unspecified) try put(alloc, &value, "severity", .{ .integer = @backingInt(item.severity) });
                    if (item.source) |source| try put(alloc, &value, "source", .{ .string = source });
                    if (item.code) |code| try put(alloc, &value, "code", code);
                    if (item.data) |data| try put(alloc, &value, "data", data);
                    try diagnostic_values.append(value);
                };
                var context = object(alloc);
                try put(alloc, &context, "diagnostics", .{ .array = diagnostic_values });
                try put(alloc, &context, "triggerKind", .{ .integer = 1 });
                try put(alloc, &params, "context", context);
            }
        }
        var method = methodFor(action);
        if (action == .semantic_tokens) if (synced.tokens) |tokens| if (tokens.value.result_id) |id| {
            const options = p.field(s.pipe.capabilities.options, provider) orelse .null;
            const full = p.field(options, "full") orelse .null;
            if (f.optionalBool(full, "delta", false) catch false) {
                method = "textDocument/semanticTokens/full/delta";
                try put(alloc, &params, "previousResultId", .{ .string = id });
            }
        };
        const id = try s.pipe.request(method, params, self.screen_context);
        self.pending = .{ .session = s.pipe.session, .id = id, .action = action, .context = self.screen_context, .revision = d.revision, .cursor = cursor };
        self.message("Language request pending…");
    }
    fn addRow(self: *Controller, label: []const u8, payload: @FieldType(Row, "payload")) !void {
        if (self.rows.items.len >= f.max_items) return;
        try self.rows.append(self.allocator(), .{ .label = try f.plainText(self.allocator(), prefixText(label, 2048)), .payload = payload });
    }
    fn showRows(self: *Controller, title: [:0]const u8) !void {
        const labels = try self.allocator().alloc([]const u8, self.rows.items.len);
        for (self.rows.items, labels) |row, *label| label.* = row.label;
        self.mode = .picker;
        self.ui.show(self.app, title, if (labels.len == 0) "No results." else "Select a result. Edits and executable commands require a separate review.", labels, false, if (labels.len != 0) "Select" else null);
    }
    fn present(self: *Controller, s: *Session, pending: Pending, result: Value) !void {
        const alloc = self.allocator();
        const d = self.app.documents.get(pending.context.doc_id orelse return error.NoDocument) orelse return error.DocumentClosed;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const synced = s.doc(d.id) orelse return error.DocumentClosed;
        const encoding = s.pipe.capabilities.encoding;
        switch (pending.action) {
            .completion => {
                var parsed = try f.parse(.completion, a, result, text, encoding);
                defer parsed.deinit();
                for (parsed.value.items) |item| {
                    if (!item.insertable) {
                        const label = try std.fmt.allocPrint(alloc, "{s} — unavailable: unsupported snippet syntax", .{item.label});
                        try self.addRow(label, .none);
                        continue;
                    }
                    var replacements: std.ArrayList(f.Replacement) = .empty;
                    defer replacements.deinit(a);
                    if (item.edit) |edit| try replacements.append(a, try edit.replacement(text, encoding, .replace)) else {
                        var prefix = pending.cursor;
                        while (prefix > 0 and (std.ascii.isAlphanumeric(text[prefix - 1]) or text[prefix - 1] == '_')) : (prefix -= 1) {}
                        try replacements.append(a, .{ .start = prefix, .end = pending.cursor, .text = item.insert_text });
                    }
                    for (item.additional_edits) |edit| try replacements.append(a, try edit.replacement(text, encoding, .replace));
                    const value = try self.replacementEdit(synced.uri, text, replacements.items, encoding);
                    try self.addRow(item.label, .{ .edit = value });
                    if (item.command) |command| self.rows.items[self.rows.items.len - 1].after_command = try json(alloc, command);
                }
            },
            .hover => {
                var parsed = try f.parse(.hover, a, result, text, encoding);
                defer parsed.deinit();
                var body: std.ArrayList(u8) = .empty;
                if (parsed.value) |hover| for (hover.contents) |part| {
                    try body.appendSlice(alloc, part.text);
                    try body.appendSlice(alloc, "\n\n");
                };
                self.mode = .info;
                self.ui.show(self.app, "Language: Hover", body.items, &.{}, false, null);
                return;
            },
            .signature => {
                var parsed = try f.parse(.signatures, a, result, text, encoding);
                defer parsed.deinit();
                var body: std.ArrayList(u8) = .empty;
                if (parsed.value) |signatures| for (signatures.signatures) |signature| {
                    try body.appendSlice(alloc, signature.label);
                    if (signature.documentation) |doc| {
                        try body.appendSlice(alloc, "\n");
                        try body.appendSlice(alloc, doc.text);
                    }
                    try body.appendSlice(alloc, "\n\n");
                };
                self.mode = .info;
                self.ui.show(self.app, "Language: Signature", body.items, &.{}, false, null);
                return;
            },
            .definition, .declaration, .type_definition, .implementation, .references => {
                var parsed = try f.parse(.definitions, a, result, text, encoding);
                defer parsed.deinit();
                for (parsed.value) |loc| try self.locationRow(loc.uri, loc.selection_range orelse loc.range, loc.uri);
            },
            .document_symbols, .workspace_symbols => {
                if (pending.action == .document_symbols) {
                    var parsed = try f.parse(.document_symbols, a, result, text, encoding);
                    defer parsed.deinit();
                    try self.symbolRows(parsed.value, synced.uri, text, encoding);
                } else {
                    var parsed = try f.parse(.workspace_symbols, a, result, text, encoding);
                    defer parsed.deinit();
                    try self.symbolRows(parsed.value, synced.uri, text, encoding);
                }
            },
            .formatting, .range_formatting => {
                var parsed = try f.parse(.text_edits, a, result, text, encoding);
                defer parsed.deinit();
                var replacements: std.ArrayList(f.Replacement) = .empty;
                defer replacements.deinit(a);
                for (parsed.value) |edit| try replacements.append(a, try edit.replacement(text, encoding, .replace));
                try self.review(s, try self.replacementEdit(synced.uri, text, replacements.items, encoding), null);
                return;
            },
            .rename => {
                if (result == .null) return error.NoRenameEdits;
                try self.review(s, result, null);
                return;
            },
            .code_actions => {
                if (result != .null) for (try f.array(result, f.max_items)) |item| {
                    if (f.field(item, "disabled") != null) continue;
                    const title = try f.string(try f.required(item, "title"));
                    if (f.field(item, "edit")) |edit| {
                        try self.addRow(title, .{ .edit = try clone(alloc, edit) });
                        if (f.field(item, "command")) |command| self.rows.items[self.rows.items.len - 1].after_command = try clone(alloc, command);
                    } else if (f.field(item, "command")) |cmd| {
                        try self.addRow(title, .{ .command = try clone(alloc, if (cmd == .string) item else cmd) });
                    } else try self.addRow(title, .{ .resolve_action = try clone(alloc, item) });
                };
            },
            .inlay_hints => {
                var parsed = try f.parse(.inlay_hints, a, result, text, encoding);
                defer parsed.deinit();
                for (parsed.value) |hint| {
                    var label: std.ArrayList(u8) = .empty;
                    for (hint.label) |part| try label.appendSlice(alloc, part.value);
                    const pos = try positions.positionAt(text, hint.position, encoding);
                    try self.locationRow(synced.uri, .{ .start = pos, .end = pos }, label.items);
                }
            },
            .code_lenses => {
                var parsed = try f.parse(.code_lenses, a, result, text, encoding);
                defer parsed.deinit();
                for (parsed.value, 0..) |lens, i| {
                    if (lens.command) |command| {
                        try self.addRow(command.title, .{ .command = try json(alloc, command) });
                    } else try self.addRow("Resolve code lens…", .{ .resolve_lens = try clone(alloc, (try f.array(result, f.max_items))[i]) });
                }
            },
            .document_links => {
                var parsed = try f.parse(.document_links, a, result, text, encoding);
                defer parsed.deinit();
                for (parsed.value, 0..) |link, i| if (link.target) |target| {
                    try self.addRow(link.tooltip orelse target, .{ .link = try alloc.dupe(u8, target) });
                } else {
                    try self.addRow("Resolve document link…", .{ .resolve_link = try clone(alloc, (try f.array(result, f.max_items))[i]) });
                };
            },
            .semantic_tokens => {
                const legend = try self.decodeLegend(s);
                const next = try f.parseSemanticTokens(a, result, text, encoding, legend, if (synced.tokens) |old| old.value else null);
                if (synced.tokens) |*old| old.deinit();
                synced.tokens = next;
                synced.semantic_revision = d.revision;
                try decorations.semantic(d, text, next.value.tokens, legend);
                const msg = u.fmt("Applied {d} semantic tokens (native emphasis tags).", .{next.value.tokens.len});
                defer a.free(msg);
                self.message(msg);
                return;
            },
        }
        try self.showRows("Language results");
    }
    fn decodeLegend(self: *Controller, s: *Session) !f.Legend {
        const provider = try f.required(s.pipe.capabilities.options, "semanticTokensProvider");
        const raw = try f.required(provider, "legend");
        const types = try f.array(try f.required(raw, "tokenTypes"), f.max_items);
        const modifiers = try f.array(try f.required(raw, "tokenModifiers"), 31);
        const t = try self.allocator().alloc([]const u8, types.len);
        const m = try self.allocator().alloc([]const u8, modifiers.len);
        for (types, t) |v, *out| out.* = try f.string(v);
        for (modifiers, m) |v, *out| out.* = try f.string(v);
        return .{ .token_types = t, .token_modifiers = m };
    }
    fn locationRow(self: *Controller, target: []const u8, range: positions.Range, title: []const u8) !void {
        const label = try std.fmt.allocPrint(self.allocator(), "{s} — {s}:{d}:{d}", .{ title, target, range.start.line + 1, range.start.character + 1 });
        try self.addRow(label, .{ .location = .{ .uri = try self.allocator().dupe(u8, target), .range = range } });
    }
    fn symbolRows(self: *Controller, symbols: []const f.Symbol, source: []const u8, text: []const u8, encoding: positions.Encoding) !void {
        for (symbols) |symbol| {
            if (symbol.location) |loc| try self.locationRow(loc.uri, loc.selection_range orelse loc.range, symbol.name) else if (symbol.selection_range orelse symbol.range) |range| try self.locationRow(source, .{ .start = try positions.positionAt(text, range.start, encoding), .end = try positions.positionAt(text, range.end, encoding) }, symbol.name);
            if (symbol.unresolved_uri) |target| {
                const value = try json(self.allocator(), .{ .name = symbol.name, .kind = symbol.kind, .location = .{ .uri = target }, .data = symbol.data });
                try self.addRow(symbol.name, .{ .resolve_symbol = value });
            }
            try self.symbolRows(symbol.children, source, text, encoding);
        }
    }
    fn replacementEdit(self: *Controller, target: []const u8, text: []const u8, replacements: []f.Replacement, encoding: positions.Encoding) !Value {
        try edits.validateReplacements(text, replacements);
        const alloc = self.allocator();
        var list: std.ArrayList(Value) = .empty;
        for (replacements) |replacement| try list.append(alloc, try json(alloc, .{ .range = .{ .start = try positions.positionAt(text, replacement.start, encoding), .end = try positions.positionAt(text, replacement.end, encoding) }, .newText = replacement.text }));
        var changes = object(alloc);
        var values = std.json.Array.init(alloc);
        try values.appendSlice(list.items);
        try put(alloc, &changes, target, .{ .array = values });
        var value = object(alloc);
        try put(alloc, &value, "changes", changes);
        return value;
    }
    fn resourceCurrent(self: *Controller, request_resource: *const resources.Request) bool {
        if (request_resource.cancelled) return false;
        const s = self.session(request_resource.session) orelse return false;
        if (!self.valid(s) or s.pipe.state != .ready or !std.mem.eql(u8, &s.digest, &request_resource.digest) or !s.pipe.isCurrent(request_resource.origin)) return false;
        if (request_resource.origin.doc_id) |id| {
            const d = self.app.documents.get(id) orelse return false;
            if (d.revision != request_resource.revision) return false;
        }
        if (request_resource.token) |token| {
            const now = c.g_get_monotonic_time();
            if (now >= request_resource.deadline) return false;
            for (s.pipe.incoming) |slot| if (slot) |incoming| {
                if (incoming.token == token) return @as(u64, @intCast(@divTrunc(now, 1000))) < incoming.deadline;
            };
            return false;
        }
        return true;
    }
    /// Called on the GTK thread after preparation and again at final admission.
    /// Workers retain only GCancellable and pinned filesystem descriptors.
    pub fn authorizeResource(self: *Controller, request_resource: *const resources.Request) !void {
        if (!self.resourceCurrent(request_resource)) return error.StaleResourceAuthorization;
        if (self.app.workspace_operations.state == .confirming and !self.approval_dispatch) return error.FreshConfigurationRequired;
    }
    pub fn completeResource(self: *Controller, request_resource: *resources.Request, result: operations.Result) void {
        std.debug.assert(self.resource == request_resource);
        self.resource = null;
        self.resource_review_shown = false;
        self.ui.close();
        if (request_resource.token) |token| if (self.session(request_resource.session)) |s| {
            // A committed syscall remains success even if cancellation races its
            // callback. Never answer success from the confirmation button itself.
            self.replyEdit(s, token, result.applied, result.reason orelse "");
        };
        if (self.mode == .resource) self.mode = .info;
        if (result.applied) self.message("Language resource operation completed on disk. There is no undo.") else {
            const text = u.fmt("Language resource operation not applied: {s}", .{result.reason orelse "Rejected"});
            defer a.free(text);
            self.message(text);
        }
        request_resource.destroy();
    }

    /// Called for committed Explorer and language operations in every live owner.
    /// Only statically registered did* filters are supported; will*/dynamic
    /// registrations are deliberately not advertised.
    pub fn fileOperationCompleted(self: *Controller, kind: operations.fs.Kind, source: []const u8, destination: []const u8, directory: bool) void {
        if (self.app.closing) return;
        for (self.sessions) |slot| if (slot) |s| {
            if (!self.valid(s) or s.pipe.state != .ready) continue;
            self.notifyFileOperation(s, kind, source, destination, directory) catch |err| self.failure(err);
        };
    }
    fn notifyFileOperation(self: *Controller, s: *Session, kind: operations.fs.Kind, source: []const u8, destination: []const u8, directory: bool) !void {
        const member: []const u8 = switch (kind) {
            .create_file, .create_directory => "didCreate",
            .rename, .move => "didRename",
            .delete => "didDelete",
        };
        const method: []const u8 = switch (kind) {
            .create_file, .create_directory => "workspace/didCreateFiles",
            .rename, .move => "workspace/didRenameFiles",
            .delete => "workspace/didDeleteFiles",
        };
        const workspace = f.field(s.pipe.capabilities.options, "workspace") orelse return;
        const registration = f.field(f.field(workspace, "fileOperations") orelse return, member) orelse return;
        const source_matches = source.len != 0 and pathWithin(s.path, source) and try file_operations.matches(registration, source, directory);
        const destination_matches = destination.len != 0 and pathWithin(s.path, destination) and try file_operations.matches(registration, destination, directory);
        if (!source_matches and !destination_matches) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value = switch (kind) {
            .create_file, .create_directory => try json(alloc, .{ .files = .{.{ .uri = try uri.fromPath(alloc, destination) }} }),
            .rename, .move => try json(alloc, .{ .files = .{.{ .oldUri = try uri.fromPath(alloc, source), .newUri = try uri.fromPath(alloc, destination) }} }),
            .delete => try json(alloc, .{ .files = .{.{ .uri = try uri.fromPath(alloc, source) }} }),
        };
        try s.pipe.notify(method, value);
        self.file_notifications += 1;
    }

    fn review(self: *Controller, s: *Session, value: Value, token: ?u64) !void {
        if (!self.valid(s)) return error.Restricted;
        // Prevalidate the ENTIRE edit before opening targets or starting workers.
        // Single resources use the reviewed Explorer path, never the text loader.
        var parsed = try edits.parse(a, value);
        defer parsed.deinit();
        for (parsed.value.operations) |operation| if (operation == .resource) {
            if (parsed.value.operations.len != 1) return error.MixedOrMultipleResourceEditsUnsupported;
            if (self.resource != null) return error.ResourceOperationPending;
            if (self.after_command != null) return error.ResourceEditWithFollowupCommandUnsupported;
            const request_resource = try resources.Request.create(self.app, s.pipe.session, s.root, s.path, s.digest, self.screen_context, self.screen_revision, token, self.server_deadline, parsed.value, value);
            self.resource = request_resource;
            self.resource_review_shown = false;
            self.mode = .resource;
            request_resource.submit() catch |err| {
                self.resource = null;
                request_resource.destroy();
                return err;
            };
            // Submission may complete synchronously on a preflight failure.
            if (self.resource != null) self.message("Preparing language resource review — no filesystem writes until confirmation.");
            return;
        };
        var targets: std.ArrayList(ReviewTarget) = .empty;
        var needs_load = false;
        for (parsed.value.operations) |operation| switch (operation) {
            .resource => unreachable, // Resources were routed or rejected above.
            .text => |edit| {
                const path = try uri.toPath(self.allocator(), edit.uri);
                if ((try self.app.browser.model.?.ownerOfCanonicalPath(path)) != s.root) return error.EditOutsideSessionRoot;
                const d = self.app.documents.findPath(path);
                if (d == null) {
                    if (edit.version != null) return error.VersionedEditForUnopenedDocument;
                    needs_load = true;
                }
                try targets.append(self.allocator(), .{ .path = path, .id = if (d) |doc| doc.id else null, .revision = if (d) |doc| doc.revision else null });
            },
        };
        self.server_token = token;
        if (needs_load) {
            self.review_load = .{ .value = try clone(self.allocator(), value), .targets = targets.items, .deadline = c.g_get_monotonic_time() + 15_000_000 };
            self.mode = .review_loading;
            self.message("Loading edit targets through workspace admission; no edits applied yet…");
            return;
        }
        try self.buildReview(s, value);
    }
    fn finishReviewLoad(self: *Controller) !void {
        const loading = self.review_load orelse return;
        const s = self.screenSession() orelse return error.StaleSession;
        try self.checkScreen(s);
        if (c.g_get_monotonic_time() > loading.deadline) return error.EditTargetLoadTimedOut;
        for (loading.targets) |*target| {
            if (target.id) |id| {
                const d = self.app.documents.get(id) orelse return error.DocumentClosed;
                if (d.revision != target.revision.? or d.path == null or !std.mem.eql(u8, d.path.?, target.path)) return error.StaleRevision;
            } else {
                if (!target.requested) {
                    target.requested = true;
                    self.app.openExisting(target.path, s.root);
                    return;
                }
                if (!target.accepted) return;
                const d = self.app.documents.findPath(target.path) orelse return;
                if (d.loading or d.pending != null) return;
                if (d.busy or d.dirty()) return error.EditTargetChangedWhileLoading;
                target.id = d.id;
                target.revision = d.revision;
            }
        }
        self.review_load = null;
        try self.buildReview(s, loading.value);
    }
    fn buildReview(self: *Controller, s: *Session, value: Value) !void {
        if (!self.valid(s)) return error.Restricted;
        if (self.plan) |*old| old.deinit();
        self.plan = null;
        self.plan = try edits.build(a, value, .{ .context = self, .resolve = &resolve }, s.pipe.capabilities.encoding);
        const plan = &self.plan.?;
        if (plan.resources.len != 0) return error.ResourceRequiresNativeReview;
        if (plan.state == .blocked) return error.EditTargetsMustBeOpenInThisRoot;
        self.mode = .review;
        var body: std.ArrayList(u8) = .empty;
        const alloc = self.allocator();
        try body.appendSlice(alloc, "Review all changes below. Apply is one grouped undo transaction. Files are NOT saved. Revisions and workspace trust are rechecked at Apply.\n\n");
        for (plan.workspace.annotations) |annotation| {
            try body.appendSlice(alloc, annotation.label);
            if (annotation.description) |description| {
                try body.appendSlice(alloc, " — ");
                try body.appendSlice(alloc, description);
            }
            try body.appendSlice(alloc, "\n");
        }
        for (plan.targets) |target| {
            try body.appendSlice(alloc, target.uri);
            try body.appendSlice(alloc, "\n");
            for (target.replacements) |replacement| {
                const old = target.snapshot.?.text[replacement.start..replacement.end];
                const part = try std.fmt.allocPrint(alloc, "  bytes {d}..{d}\n− {s}\n+ {s}\n", .{ replacement.start, replacement.end, try reviewText(alloc, old), try reviewText(alloc, replacement.text) });
                if (body.items.len + part.len > 256 * 1024) return error.EditReviewTooLarge;
                try body.appendSlice(alloc, part);
            }
        }
        self.bindUI();
        self.ui.show(self.app, "Language: Review edits", body.items, &.{}, false, "Apply all reviewed edits");
    }
    fn resolve(context: *anyopaque, target: []const u8) anyerror!?edits.Snapshot {
        const self = u.cast(Controller, context);
        const s = self.screenSession() orelse return error.StaleSession;
        if (!self.valid(s)) return error.Restricted;
        const path = try uri.toPath(a, target);
        defer a.free(path);
        const d = self.app.documents.findPath(path) orelse return null;
        if (d.loading or d.pending != null or d.busy) return error.DocumentBusy;
        try self.sync(s, d);
        if (self.scratch) |old| a.free(old);
        self.scratch = u.bufferText(d.buffer);
        return .{ .uri = target, .text = self.scratch.?, .version = if (s.doc(d.id)) |synced| synced.version else null, .revision = d.revision, .id = d.id, .root_authorization = if ((self.rootFor(d) catch null) == s.root) .authorized else .outside_root };
    }
    fn apply(self: *Controller) !void {
        if (!self.approval_dispatch) return error.FreshConfigurationRequired;
        if (self.app.editingFrozen() or self.app.workspaceOperationBusy()) return error.DocumentBusy;
        const s = self.screenSession() orelse return error.StaleSession;
        try self.checkScreen(s);
        if (self.server_token != null and !self.serverReviewCurrent()) return error.ServerEditReviewExpired;
        const plan = if (self.plan) |*value| value else return error.NoReview;
        const alloc = self.allocator();
        var confirmations: std.ArrayList([]const u8) = .empty;
        for (plan.workspace.annotations) |annotation| try confirmations.append(alloc, annotation.id);
        try plan.validateForApply(.{ .context = self, .resolve = &resolve }, confirmations.items);
        const changes = try alloc.alloc(transactions.Change, plan.targets.len);
        for (plan.targets, changes) |target, *change| {
            const saved = target.snapshot.?;
            const d = self.app.documents.get(saved.id) orelse return error.DocumentClosed;
            const replacements = try alloc.alloc(transactions.Replacement, target.replacements.len);
            for (target.replacements, replacements) |source, *dest| dest.* = .{ .start = source.start, .end = source.end, .text = source.text };
            change.* = .{ .target = .{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = saved.revision, .busy = d.busy or d.loading or d.pending != null }, .replacements = replacements };
        }
        try self.app.performGrouped("Language edit", changes);
        self.plan.?.deinit();
        self.plan = null;
        self.mode = .info;
        if (self.server_token) |token| {
            self.replyEdit(s, token, true, "");
            self.server_token = null;
        }
        self.message("Language edits applied. Documents remain unsaved; grouped undo is available.");
        if (self.after_command) |command| {
            self.after_command = null;
            if (self.screen_context.doc_id) |id| {
                const d = self.app.documents.get(id) orelse return error.DocumentClosed;
                try self.sync(s, d);
                self.screen_context = s.pipe.contextFor(s.doc(id).?.uri).?;
                self.screen_revision = d.revision;
            }
            try self.confirmCommand(s, command);
        }
    }
    fn serverReviewCurrent(self: *Controller) bool {
        const token = self.server_token orelse return false;
        const s = self.screenSession() orelse return false;
        const now = c.g_get_monotonic_time();
        if (!self.valid(s) or now >= self.server_deadline) return false;
        // The client removes incoming tokens on cancellation as well as expiry.
        // Consult that authoritative bounded registry before any GTK mutation.
        for (s.pipe.incoming) |slot| if (slot) |incoming| {
            if (incoming.token == token) return @as(u64, @intCast(@divTrunc(now, 1000))) < incoming.deadline;
        };
        return false;
    }
    fn replyEdit(self: *Controller, s: *Session, token: u64, applied: bool, reason: []const u8) void {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const value = json(arena.allocator(), .{ .applied = applied, .failureReason = reason }) catch return;
        s.pipe.respond(token, value) catch {};
    }
    fn checkScreen(self: *Controller, s: *Session) !void {
        if (!self.valid(s) or s.pipe.state != .ready or self.screen_context.session != s.pipe.session) return error.StaleSession;
        if (self.screen_context.doc_id) |id| if ((self.app.documents.get(id) orelse return error.DocumentClosed).revision != self.screen_revision) return error.StaleRevision;
        if (!s.pipe.isCurrent(self.screen_context)) return error.StaleLanguageResponse;
    }
    fn choose(self: *Controller, index: usize) !void {
        if (index >= self.rows.items.len) return error.InvalidSelection;
        const s = self.screenSession() orelse return error.StaleSession;
        try self.checkScreen(s);
        const row = self.rows.items[index];
        switch (row.payload) {
            .none => return error.ResultUnavailable,
            .location => |location| try self.navigate(s, location),
            .edit => |value| {
                self.after_command = row.after_command;
                try self.review(s, value, null);
            },
            .command => |value| try self.confirmCommand(s, value),
            .link => |target| {
                if (std.ascii.startsWithIgnoreCase(target, "file:")) {
                    const zero: positions.Position = .{ .line = 0, .character = 0 };
                    try self.navigate(s, .{ .uri = target, .range = .{ .start = zero, .end = zero } });
                } else {
                    if (!std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "http://")) return error.ExternalLinkSchemeUnsupported;
                    self.external_url = target;
                    self.mode = .external;
                    self.ui.show(self.app, "Open external link?", target, &.{}, false, "Open in default browser");
                }
            },
            .resolve_lens => |value| try self.resolveRequest(s, "codeLens/resolve", "codeLensProvider", value, .lens),
            .resolve_link => |value| try self.resolveRequest(s, "documentLink/resolve", "documentLinkProvider", value, .link),
            .resolve_action => |value| try self.resolveRequest(s, "codeAction/resolve", "codeActionProvider", value, .action),
            .resolve_symbol => |value| try self.resolveRequest(s, "workspaceSymbol/resolve", "workspaceSymbolProvider", value, .symbol),
        }
    }
    fn resolveRequest(self: *Controller, s: *Session, method: []const u8, provider: []const u8, value: Value, kind: @FieldType(Pending, "kind")) !void {
        const options = try f.required(s.pipe.capabilities.options, provider);
        if (!(try f.optionalBool(options, "resolveProvider", false))) return error.ServerResolveCapabilityUnavailable;
        const id = try s.pipe.request(method, value, self.screen_context);
        self.pending = .{ .session = s.pipe.session, .id = id, .action = .code_actions, .context = self.screen_context, .revision = self.screen_revision, .cursor = self.screen_cursor, .kind = kind };
        self.message("Resolving language result…");
    }
    fn presentResolved(self: *Controller, s: *Session, pending: Pending, value: Value) !void {
        if (pending.kind == .execute) {
            self.message("Server command completed.");
            return;
        }
        const alloc = self.allocator();
        const owned = try clone(alloc, value);
        switch (pending.kind) {
            .lens => try self.confirmCommand(s, try f.required(owned, "command")),
            .link => {
                const target = try f.string(try f.required(owned, "target"));
                self.rows = .empty;
                try self.addRow(target, .{ .link = target });
                try self.choose(0);
            },
            .action => {
                if (f.field(owned, "disabled") != null) return error.CodeActionDisabled;
                if (f.field(owned, "edit")) |edit| {
                    self.after_command = f.field(owned, "command");
                    try self.review(s, edit, null);
                } else if (f.field(owned, "command")) |command| try self.confirmCommand(s, command) else return error.CodeActionHasNoEditOrCommand;
            },
            .symbol => {
                const loc = try f.required(owned, "location");
                try self.navigate(s, .{ .uri = try f.string(try f.required(loc, "uri")), .range = try f.range(try f.required(loc, "range")) });
            },
            else => unreachable,
        }
    }
    fn confirmCommand(self: *Controller, s: *Session, value: Value) !void {
        if (!s.pipe.capabilities.supports("executeCommandProvider")) return error.ServerCapabilityUnavailable;
        const command = try f.string(try f.required(value, "command"));
        const provider = try f.required(s.pipe.capabilities.options, "executeCommandProvider");
        var supported = false;
        for (try f.array(try f.required(provider, "commands"), f.max_items)) |item| if (std.mem.eql(u8, try f.string(item), command)) {
            supported = true;
        };
        if (!supported) return error.ServerCommandNotAdvertised;
        if (f.field(value, "arguments")) |args| if (args != .null) {
            _ = try f.array(args, f.max_items);
        };
        self.command_value = value;
        self.mode = .command;
        const text = try std.json.Stringify.valueAlloc(self.allocator(), value, .{ .whitespace = .indent_2, .escape_unicode = true });
        if (text.len > 64 * 1024) return error.CommandReviewTooLarge;
        const body = try std.fmt.allocPrint(self.allocator(), "Execute this server command? It has your user permissions, not a sandbox. Further workspace edits require review.\n\n{s}", .{text});
        self.ui.show(self.app, "Language: Execute command", body, &.{}, false, "Execute command");
    }
    fn executeCommand(self: *Controller, s: *Session) !void {
        if (!self.approval_dispatch) return error.FreshConfigurationRequired;
        try self.checkScreen(s);
        const alloc = self.allocator();
        var params = object(alloc);
        try put(alloc, &params, "command", try f.required(self.command_value, "command"));
        if (f.field(self.command_value, "arguments")) |args| if (args != .null) {
            try put(alloc, &params, "arguments", args);
        };
        const id = try s.pipe.request("workspace/executeCommand", params, self.screen_context);
        self.pending = .{ .session = s.pipe.session, .id = id, .action = .code_lenses, .context = self.screen_context, .revision = self.screen_revision, .cursor = self.screen_cursor, .kind = .execute };
        self.message("Server command dispatched by explicit approval; any applyEdit requires review.");
    }
    fn navigate(self: *Controller, s: *Session, location: Location) !void {
        const path = try uri.toPath(a, location.uri);
        errdefer a.free(path);
        const m = self.app.browser.model orelse return error.NoWorkspace;
        if ((try m.ownerOfCanonicalPath(path)) != s.root) return error.NavigationOutsideSessionRoot;
        self.clearNavigation();
        self.navigation = .{ .path = path, .location = .{ .uri = try a.dupe(u8, location.uri), .range = location.range }, .encoding = s.pipe.capabilities.encoding, .session = s.pipe.session, .group = self.app.activeGroupId(), .source = self.screen_context, .source_revision = self.screen_revision, .revision = if (self.app.documents.findPath(path)) |d| d.revision else null, .deadline = c.g_get_monotonic_time() + 15_000_000 };
        // Existing browser admission resolves canonical identity and rejects symlinks
        // off-thread. Range conversion waits for the destination loader to finish.
        self.app.openExisting(path, s.root);
    }
    pub fn documentLoaded(self: *Controller, d: *Document) void {
        const path = d.path orelse return;
        if (self.navigation) |*nav| if (nav.accepted and nav.revision == null and std.mem.eql(u8, path, nav.path)) {
            nav.revision = d.revision;
        };
    }
    pub fn acceptedOpen(self: *Controller, canonical: []const u8) void {
        if (self.navigation) |*nav| if (std.mem.eql(u8, canonical, nav.path)) {
            nav.accepted = true;
        };
        if (self.review_load) |loading| for (loading.targets) |*target| if (target.requested and std.mem.eql(u8, canonical, target.path)) {
            target.accepted = true;
        };
    }
    fn finishNavigation(self: *Controller) !void {
        const nav = self.navigation orelse return;
        const s = self.session(nav.session) orelse return error.StaleSession;
        if (!self.valid(s)) return error.Restricted;
        if (!s.pipe.isCurrent(nav.source)) return error.StaleLanguageResponse;
        if (nav.source.doc_id) |id| if ((self.app.documents.get(id) orelse return error.DocumentClosed).revision != nav.source_revision) return error.StaleNavigation;
        if (c.g_get_monotonic_time() > nav.deadline) return error.LanguageNavigationTimedOut;
        if (!nav.accepted) return;
        const d = self.app.documents.findPath(nav.path) orelse return;
        if (d.loading or d.pending != null) return;
        if (nav.revision) |revision| if (d.revision != revision) return error.StaleNavigation;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const range = try positions.byteRange(text, nav.location.range, nav.encoding);
        var existing: ?*@import("../editor/view.zig").EditorView = null;
        _ = self.app.groups.get(nav.group) orelse return error.NavigationGroupClosed;
        for (self.app.views.items) |view| if (view.document == d) {
            if (self.app.groups.forPage(view.page)) |group| if (group.id == nav.group) {
                existing = view;
                break;
            };
        };
        const view = existing orelse try self.app.addView(d, nav.group);
        self.app.focusView(view);
        var start = try decorations.iter(d, text, range.start);
        var end = try decorations.iter(d, text, range.end);
        // Views use independent buffer bridges; canonical character offsets map 1:1.
        c.gtk_text_buffer_get_iter_at_offset(view.buffer, &start, c.gtk_text_iter_get_offset(&start));
        c.gtk_text_buffer_get_iter_at_offset(view.buffer, &end, c.gtk_text_iter_get_offset(&end));
        c.gtk_text_buffer_select_range(view.buffer, &start, &end);
        _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, view.widget), &start, 0.15, 0, 0, 0);
        self.clearNavigation();
    }
    pub fn problems(self: *Controller) void {
        self.showProblems() catch |err| self.failure(err);
    }
    fn showProblems(self: *Controller) !void {
        self.clearScreen();
        self.bindUI();
        // Rows carry a session owner; choosing a cross-session problem retargets
        // the screen before navigation through the same root admission path.
        for (self.sessions) |slot| if (slot) |s| if (self.valid(s) and s.pipe.state == .ready) {
            for (s.docs.items) |synced| if (synced.diagnostics) |diag| {
                const d = self.app.documents.get(synced.id) orelse continue;
                if (d.revision != synced.revision) continue;
                const text = u.bufferText(d.buffer);
                defer a.free(text);
                for (diag.value.items) |item| {
                    const label = try std.fmt.allocPrint(self.allocator(), "[{s}{s}] {s}", .{ @tagName(item.severity), if (synced.verified) "" else ", unversioned/unverified", item.message });
                    if (self.rows.items.len == f.max_items) break;
                    try self.locationRow(synced.uri, .{ .start = try positions.positionAt(text, item.range.start, s.pipe.capabilities.encoding), .end = try positions.positionAt(text, item.range.end, s.pipe.capabilities.encoding) }, label);
                    const location = &self.rows.items[self.rows.items.len - 1].payload.location;
                    location.session = s.pipe.session;
                    location.document = d.id;
                    location.revision = d.revision;
                }
            };
        };
        try self.showRows("Problems — all language sessions");
    }
    pub fn summary(self: *const Controller) []const u8 {
        if (self.resource != null) return "Language: resource review";
        if (self.plan != null or self.review_load != null) return "Language: review";
        if (self.pending != null) return "Language: working…";
        var ready = false;
        for (self.sessions) |slot| if (slot) |s| switch (s.pipe.state) {
            .ready => {
                ready = true;
            },
            .starting, .initializing => return "Language: starting…",
            .stopping => return "Language: stopping…",
            .crashed => return "Language: failed",
            .stopped => {},
        };
        return if (ready) "Language: ready" else "Language: off";
    }
    pub fn showStatus(self: *Controller) void {
        if (self.pending != null or self.ui.window != null or self.review_load != null) {
            self.app.message(self.status);
            return;
        }
        self.clearScreen();
        self.bindUI();
        var body: std.ArrayList(u8) = .empty;
        const alloc = self.allocator();
        body.appendSlice(alloc, self.status) catch return;
        body.appendSlice(alloc, "\nUser configuration: ~/.config/coral/languages.json (version 1).\nExecutables are never installed automatically. Processes have user permissions, not a sandbox. Start is always explicit.\nSingle standalone Create/Rename/Delete WorkspaceEdits use the native Explorer confirmation and asynchronous workers. No overwrite, ignore-if-exists/missing, recursive delete, mixed/multiple resource operations, or resource edits with follow-up commands. Filesystem operations have no undo.\nFile-operation didCreate/didRename/didDelete notifications follow static server filters; dynamic registration and will* requests are unsupported.\nProblems covers synchronized open documents. Semantic tokens and inlay hints refresh on explicit request.\n") catch return;
        for (self.sessions) |slot| if (slot) |s| {
            const line = std.fmt.allocPrint(alloc, "\nRoot #{d}: {s} — {s}: {s}; {d} documents; configuration {s}\nPosition encoding: {s}; synchronization: {s}; trust permit valid: {}\n", .{ @backingInt(s.root), s.path, s.language, @tagName(s.pipe.state), s.docs.items.len, std.fmt.bytesToHex(&s.digest, .lower), @tagName(s.pipe.capabilities.encoding), @tagName(s.pipe.capabilities.sync), self.valid(s) }) catch return;
            body.appendSlice(alloc, line) catch return;
            inline for (@typeInfo(Action).@"enum".field_names) |name| {
                const provider = providerFor(@field(Action, name));
                const feature = std.fmt.allocPrint(alloc, "  {s}: {s}\n", .{ name, if (s.pipe.capabilities.supports(provider)) @as([]const u8, "available") else "unavailable" }) catch return;
                body.appendSlice(alloc, feature) catch return;
            }
        };
        body.appendSlice(alloc, self.progress) catch return;
        self.ui.show(self.app, "Language: Status", body.items, &.{}, false, null);
    }
    fn answered(context: *anyopaque, approved: bool, index: ?usize, input: []const u8) void {
        const self = &u.cast(App, context).language;
        if (!approved) {
            self.clearScreen();
            return;
        }
        self.answer(index, input) catch |err| {
            if (self.server_token) |token| {
                if (self.screenSession()) |s| self.replyEdit(s, token, false, @errorName(err));
                self.server_token = null;
            }
            self.clearScreen();
            self.failure(err);
        };
    }
    fn answer(self: *Controller, index: ?usize, input: []const u8) !void {
        switch (self.mode) {
            .start => try self.queueConfig(.launch, self.start_root orelse return error.NoWorkspace, self.start_language, self.start_binding),
            .rename, .workspace_query => {
                const s = self.screenSession() orelse return error.StaleSession;
                try self.checkScreen(s);
                const view = self.app.activeView() orelse return error.RequestOriginChanged;
                if (view.document.id != self.screen_context.doc_id) return error.RequestOriginChanged;
                var caret: c.GtkTextIter = undefined;
                c.gtk_text_buffer_get_iter_at_mark(view.buffer, &caret, c.gtk_text_buffer_get_insert(view.buffer));
                const source_text = u.bufferText(view.document.buffer);
                defer a.free(source_text);
                if (try byteAt(source_text, c.gtk_text_iter_get_offset(&caret)) != self.screen_cursor) return error.RequestOriginChanged;
                const owned = u.z(input);
                defer a.free(owned);
                if (owned.len == 0) return error.EmptyInput;
                try self.begin(if (self.mode == .rename) .rename else .workspace_symbols, owned);
            },
            .picker => {
                const i = index orelse return error.SelectResult;
                if (self.screen_session == null and i < self.rows.items.len) {
                    const row = self.rows.items[i];
                    if (row.payload == .location) {
                        const location = row.payload.location;
                        const s = self.session(location.session orelse return error.StaleSession) orelse return error.StaleSession;
                        const d = self.app.documents.get(location.document orelse return error.DocumentClosed) orelse return error.DocumentClosed;
                        if (d.revision != location.revision) return error.StaleDiagnostics;
                        self.screen_session = s.pipe.session;
                        self.screen_context = s.pipe.contextFor(location.uri) orelse return error.DocumentClosed;
                        self.screen_revision = d.revision;
                    }
                }
                try self.choose(i);
            },
            .review, .command, .external, .resource => try self.queueConfig(.approve, null, "", null),
            .info, .review_loading => {},
        }
    }
    pub fn probe(self: *Controller) void {
        if (!@import("build_options").test_hooks) return;
        var count: usize = 0;
        var diagnostic_count: usize = 0;
        for (self.sessions) |slot| if (slot) |s| {
            count += 1;
            for (s.docs.items) |d| if (d.diagnostics) |diag| {
                diagnostic_count += diag.value.items.len;
            };
            const lang = u.z(s.language);
            defer a.free(lang);
            c.g_print("CORAL_LANGUAGE_SESSION id=%lu root=%lu language=%s state=%s documents=%lu\n", s.pipe.session, @backingInt(s.root), lang.ptr, @tagName(s.pipe.state).ptr, s.docs.items.len);
        };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const DocProbe = struct { id: u64, uri: []const u8, revision: u64, version: i32, diagnostics: usize, verified: bool, semantic_tokens: usize };
        const SessionProbe = struct { id: u64, root: u64, path: []const u8, language: []const u8, state: []const u8, config: []const u8, documents: []const DocProbe };
        var sessions: std.ArrayList(SessionProbe) = .empty;
        for (self.sessions) |slot| if (slot) |s| {
            const docs = alloc.alloc(DocProbe, s.docs.items.len) catch return;
            for (s.docs.items, docs) |d, *out| out.* = .{ .id = d.id, .uri = d.uri, .revision = d.revision, .version = d.version, .diagnostics = if (d.diagnostics) |diag| diag.value.items.len else 0, .verified = d.verified, .semantic_tokens = if (d.semantic_revision == d.revision) if (d.tokens) |tokens| tokens.value.tokens.len else 0 else 0 };
            sessions.append(alloc, .{ .id = s.pipe.session, .root = @backingInt(s.root), .path = s.path, .language = s.language, .state = @tagName(s.pipe.state), .config = alloc.dupe(u8, &std.fmt.bytesToHex(&s.digest, .lower)) catch return, .documents = docs }) catch return;
        };
        const TagProbe = struct { document: u64, view: ?u64, diagnostic_ranges: usize, semantic_ranges: usize, diagnostic_kinds: usize, semantic_kinds: usize, truncated: bool };
        var tag_probes: std.ArrayList(TagProbe) = .empty;
        for (self.app.documents.entries.items) |d| {
            const diagnostic = decorations.appliedRanges(d.buffer, false);
            const semantic = decorations.appliedRanges(d.buffer, true);
            tag_probes.append(alloc, .{ .document = d.id, .view = null, .diagnostic_ranges = diagnostic.count, .semantic_ranges = semantic.count, .diagnostic_kinds = diagnostic.kinds, .semantic_kinds = semantic.kinds, .truncated = diagnostic.truncated or semantic.truncated }) catch return;
        }
        for (self.app.views.items) |view| {
            const diagnostic = decorations.appliedRanges(view.buffer, false);
            const semantic = decorations.appliedRanges(view.buffer, true);
            tag_probes.append(alloc, .{ .document = view.document.id, .view = @intCast(view.id), .diagnostic_ranges = diagnostic.count, .semantic_ranges = semantic.count, .diagnostic_kinds = diagnostic.kinds, .semantic_kinds = semantic.kinds, .truncated = diagnostic.truncated or semantic.truncated }) catch return;
        }
        const labels = alloc.alloc([]const u8, self.rows.items.len) catch return;
        for (self.rows.items, labels) |row, *label| label.* = row.label;
        const bytes = std.json.Stringify.valueAlloc(alloc, .{ .window = self.app.window_id, .sessions = sessions.items, .session_count = count, .diagnostics = diagnostic_count, .pending = if (self.pending) |pending| @as(?[]const u8, @tagName(pending.action)) else null, .pending_kind = if (self.pending) |pending| @as(?[]const u8, @tagName(pending.kind)) else null, .config_check = if (self.config_job) |job| @as(?[]const u8, @tagName(job.kind)) else null, .config_queued = self.config_queued != null, .config_generation = self.config_generation, .decoration_buffers = tag_probes.items, .tags = tag_probes.items, .review = self.plan != null, .review_loading = self.review_load != null, .server_review = self.server_token != null or (if (self.resource) |r| r.token != null else false), .resource_review = self.resource != null, .resource_state = if (self.resource != null) @as(?[]const u8, @tagName(self.app.workspace_operations.state)) else null, .resource_kind = if (self.resource) |r| @as(?[]const u8, @tagName(r.kind)) else null, .resource_source = if (self.resource) |r| @as(?[]const u8, r.source) else null, .resource_destination = if (self.resource) |r| @as(?[]const u8, r.destination) else null, .file_notifications_queued = self.file_notifications, .navigation = self.navigation != null, .rows = labels, .mode = @tagName(self.mode), .dialog = self.ui.window != null or (self.resource != null and self.app.workspace_operations.dialog != null), .status = self.status, .progress = self.progress, .popup = if (self.ui.body) |label| std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, label))) else if (self.resource) |r| r.review else "" }, .{}) catch return;
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_LANGUAGE %s\n", line.ptr);
    }
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!@import("build_options").test_hooks) return false;
        if (std.mem.eql(u8, action, "language-config-unwatch")) {
            self.clearConfigMonitors();
            self.config_monitors_dirty = false;
            self.test_config_poll_disabled = true;
        } else if (std.mem.eql(u8, action, "language-probe")) self.probe() else if (std.mem.eql(u8, action, "language-accept")) {
            self.showResourceReview();
            self.ui.answer(true, std.fmt.parseInt(usize, value, 10) catch 0, value);
        } else if (std.mem.eql(u8, action, "language-reject")) {
            self.clearScreen();
        } else return false;
        return true;
    }
};
const ConfigKind = enum { poll, start, launch, approve };
const ConfigJob = struct {
    owner: *Controller,
    kind: ConfigKind,
    root: ?RootId,
    language: []u8,
    expected: ?config.Binding,
    generation: u64,
    screen: u64,
    mode: Mode,
    session: ?u64,
    deadline: i64 = 0,
    timed_out: bool = false,
    result: ?config.Config = null,
    err: ?anyerror = null,
    fn destroy(self: *ConfigJob) void {
        if (self.result) |*result| result.deinit();
        a.free(self.language);
        a.destroy(self);
    }
    fn run(self: *ConfigJob) !void {
        var first = try config.load();
        defer first.deinit();
        var second = try config.load();
        errdefer second.deinit();
        if (!first.binding().same(second.binding())) return error.LanguageConfigChangedDuringRead;
        self.result = second;
    }
};
fn configWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(ConfigJob, data.?);
    job.run() catch |err| {
        job.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn configDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(ConfigJob, data.?);
    const self = job.owner;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.config_job == job);
    self.config_job = null;
    defer {
        job.destroy();
        if (self.config_queued) |next| {
            self.config_queued = null;
            if (!self.app.closing and next.generation == self.config_generation and next.screen == self.screen_generation) self.dispatchConfig(next) else next.destroy();
        }
        self.app.release();
    }
    if (self.app.closing or job.timed_out or job.generation != self.config_generation or (job.kind != .poll and job.screen != self.screen_generation)) return;
    if (job.err) |err| {
        self.invalidate();
        self.failure(err);
        return;
    }
    self.configReady(job) catch |err| {
        if (err == error.LanguageConfigChanged or err == error.LanguageConfigChangedReviewAgain) self.invalidate() else self.clearScreen();
        self.failure(err);
    };
}
fn configurationChanged(monitor: ?*c.GFileMonitor, file: ?*c.GFile, other: ?*c.GFile, event: c.GFileMonitorEvent, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.app.closing) return;
    var relevant = event == c.G_FILE_MONITOR_EVENT_UNMOUNTED;
    const children = [_][]const u8{ ".config", "coral", "languages.json" };
    for (self.config_monitors, 0..) |slot, i| if (slot != null and slot == monitor) {
        if (i == 3) {
            relevant = true;
            break;
        }
        for ([_]?*c.GFile{ file, other }) |candidate| if (candidate) |entry| {
            const name = c.g_file_get_basename(entry);
            defer c.g_free(name);
            if (name != null and std.mem.eql(u8, std.mem.span(name), children[i])) relevant = true;
        };
    };
    if (!relevant) return;
    self.config_monitors_dirty = true;
    self.invalidate();
    if (self.timer == 0) self.timer = c.g_timeout_add(20, &tick, self);
    self.message("Language configuration changed. Sessions stopped; review and explicitly Start again.");
}
fn pathWithin(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and (std.mem.eql(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    self.pump();
    for (self.sessions) |s| if (s != null) return 1;
    if (self.config_job != null or self.config_queued != null) return 1;
    self.timer = 0;
    return 0;
}
fn object(alloc: std.mem.Allocator) Value {
    _ = alloc;
    return .{ .object = .empty };
}
fn put(alloc: std.mem.Allocator, value: *Value, key: []const u8, child: Value) !void {
    try value.object.put(alloc, key, child);
}
fn json(alloc: std.mem.Allocator, value: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
    return (try p.parseMessage(alloc, bytes)).value;
}
fn clone(alloc: std.mem.Allocator, value: Value) !Value {
    return json(alloc, value);
}
// Keep ordinary source readable, but never hide control/bidi code in an edit
// approval. JSON escaping is display-only; transactions retain the exact bytes.
fn reviewText(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |cp| {
        if ((cp < 32 and cp != 9 and cp != 10) or (cp >= 127 and cp <= 159) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069))
            return std.json.Stringify.valueAlloc(alloc, text, .{ .escape_unicode = true });
    }
    return text;
}
fn prefixText(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) : (end -= 1) {}
    return text[0..end];
}
fn byteAt(text: []const u8, character: c_int) !usize {
    if (character < 0) return error.InvalidPosition;
    var i: usize = 0;
    var n: c_int = 0;
    while (n < character) : (n += 1) {
        if (i == text.len) return error.InvalidPosition;
        i += try std.unicode.utf8ByteSequenceLength(text[i]);
    }
    return i;
}
fn providerFor(action: Action) []const u8 {
    return switch (action) {
        .completion => "completionProvider",
        .hover => "hoverProvider",
        .signature => "signatureHelpProvider",
        .definition => "definitionProvider",
        .declaration => "declarationProvider",
        .type_definition => "typeDefinitionProvider",
        .implementation => "implementationProvider",
        .references => "referencesProvider",
        .document_symbols => "documentSymbolProvider",
        .workspace_symbols => "workspaceSymbolProvider",
        .formatting => "documentFormattingProvider",
        .range_formatting => "documentRangeFormattingProvider",
        .rename => "renameProvider",
        .code_actions => "codeActionProvider",
        .semantic_tokens => "semanticTokensProvider",
        .inlay_hints => "inlayHintProvider",
        .code_lenses => "codeLensProvider",
        .document_links => "documentLinkProvider",
    };
}
fn methodFor(action: Action) []const u8 {
    return switch (action) {
        .completion => "textDocument/completion",
        .hover => "textDocument/hover",
        .signature => "textDocument/signatureHelp",
        .definition => "textDocument/definition",
        .declaration => "textDocument/declaration",
        .type_definition => "textDocument/typeDefinition",
        .implementation => "textDocument/implementation",
        .references => "textDocument/references",
        .document_symbols => "textDocument/documentSymbol",
        .workspace_symbols => "workspace/symbol",
        .formatting => "textDocument/formatting",
        .range_formatting => "textDocument/rangeFormatting",
        .rename => "textDocument/rename",
        .code_actions => "textDocument/codeAction",
        .semantic_tokens => "textDocument/semanticTokens/full",
        .inlay_hints => "textDocument/inlayHint",
        .code_lenses => "textDocument/codeLens",
        .document_links => "textDocument/documentLink",
    };
}
