//! A language-owned lease on the production reviewed Explorer operation pipeline.
//! No filesystem mutation or GTK work occurs in this request's construction.
const std = @import("std");
const u = @import("../c.zig");
const App = @import("../app.zig").App;
const operations = @import("../workspace/operations_controller.zig");
const RootId = @import("../workspace/model.zig").RootId;
const client = @import("client.zig");
const config = @import("config.zig");
const edits = @import("edits.zig");
const uri = @import("uri.zig");

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    app: *App,
    session: u64,
    root: RootId,
    digest: config.Digest,
    origin: client.Context,
    revision: u64,
    token: ?u64,
    deadline: i64,
    kind: operations.fs.Kind,
    source: []const u8,
    destination: []const u8,
    review: []const u8,
    cancelled: bool = false,

    pub fn create(app: *App, session: u64, root: RootId, root_path: []const u8, digest: config.Digest, origin: client.Context, revision: u64, token: ?u64, deadline: i64, edit: edits.WorkspaceEdit, value: std.json.Value) !*Request {
        if (edit.operations.len != 1 or edit.operations[0] != .resource) return error.MixedOrMultipleResourceEditsUnsupported;
        var arena = std.heap.ArenaAllocator.init(u.a);
        errdefer arena.deinit();
        const a = arena.allocator();
        var kind: operations.fs.Kind = undefined;
        var source: []const u8 = "";
        var destination: []const u8 = "";
        switch (edit.operations[0].resource) {
            .create => |op| {
                if (op.options.overwrite or op.options.ignore_if_exists) return error.ResourceOverwriteOrIgnoreOptionsUnsupported;
                kind = .create_file;
                destination = try relative(app, a, root, root_path, op.uri);
            },
            .rename => |op| {
                if (op.options.overwrite or op.options.ignore_if_exists) return error.ResourceOverwriteOrIgnoreOptionsUnsupported;
                kind = .rename;
                source = try relative(app, a, root, root_path, op.old_uri);
                destination = try relative(app, a, root, root_path, op.new_uri);
            },
            .delete => |op| {
                if (op.options.recursive or op.options.ignore_if_not_exists) return error.ResourceRecursiveOrIgnoreOptionsUnsupported;
                kind = .delete;
                source = try relative(app, a, root, root_path, op.uri);
            },
        }
        const encoded = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2, .escape_unicode = true });
        if (encoded.len > 48 * 1024) return error.ResourceReviewTooLarge;
        const review = try std.fmt.allocPrint(a, "Language server resource edit — one standalone operation.\nThis changes the filesystem immediately after confirmation, not an unsaved buffer. There is no undo.\n{s}\nOptions: overwrite=false; ignoreIfExists=false; recursive=false; ignoreIfNotExists=false.\nAll change annotations below are included in this explicit confirmation.\n\n{s}", .{ if (kind == .delete) @as([]const u8, "Permanent deletion: regular files and empty directories only. No trash, recursive deletion, or undo.") else "Existing destinations are never replaced.", encoded });
        const self = try u.a.create(Request);
        self.* = .{ .arena = arena, .app = app, .session = session, .root = root, .digest = digest, .origin = origin, .revision = revision, .token = token, .deadline = deadline, .kind = kind, .source = source, .destination = destination, .review = review };
        return self;
    }
    pub fn destroy(self: *Request) void {
        self.arena.deinit();
        u.a.destroy(self);
    }
    pub fn submit(self: *Request) !void {
        try self.app.workspace_operations.submitReviewed(.{ .root = self.root, .kind = self.kind, .source = self.source, .destination = self.destination, .review = self.review, .context = self, .authorize = &authorize, .complete = &complete });
    }
    pub fn cancel(self: *Request) void {
        self.cancelled = true;
        self.app.workspace_operations.cancelSubmitted(self);
    }
    fn authorize(context: *anyopaque) !void {
        const self = u.cast(Request, context);
        try self.app.language.authorizeResource(self);
    }
    fn complete(context: *anyopaque, result: operations.Result) void {
        const self = u.cast(Request, context);
        self.app.language.completeResource(self, result);
    }
};

fn relative(app: *App, a: std.mem.Allocator, root: RootId, root_path: []const u8, target: []const u8) ![]const u8 {
    const path = try uri.toPath(a, target);
    const model = app.browser.model orelse return error.NoWorkspace;
    if ((try model.ownerOfCanonicalPath(path)) != root) return error.ResourceOutsideSessionRoot;
    if (std.mem.eql(u8, path, root_path)) return error.RootMutation;
    const prefix = if (std.mem.eql(u8, root_path, "/")) root_path else try std.fmt.allocPrint(a, "{s}/", .{root_path});
    if (!std.mem.startsWith(u8, path, prefix)) return error.ResourceOutsideSessionRoot;
    return path[prefix.len..];
}
