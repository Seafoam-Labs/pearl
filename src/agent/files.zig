//! Local filesystem executor for assistant file tools (Phases 3-5).
//!
//! Security model: every path operation is fd-relative and resolved with
//! Linux openat2(RESOLVE_BENEATH|NO_SYMLINKS|NO_MAGICLINKS|NO_XDEV). Grant
//! roots are opened once, their dev/ino identity is pinned, and every
//! operation re-verifies that the configured root path still resolves to that
//! identity. Model-visible file ids are opaque host strings bound to a held
//! open dirfd plus a statx identity; the model never supplies paths. Mutations
//! (create/delete) require an ActionPreview produced by prepare() and passed
//! back to execute(), which revalidates the exact approved identity before
//! touching anything. Delete uses GIO trash (which renames the directory entry
//! itself and never follows a final symlink); permanent deletion only happens
//! with an explicit delete_file_permanent preview, issued when trash is
//! unsupported on the file's mount. There is no permanent fallback.
//!
//! Known limits (documented by design):
//! - openat2 is required; kernels without it fail closed (ResolverUnsupported).
//! - GIO trash is anchored at /proc/self/fd/<parentfd>/<basename>. The parent
//!   inode is pinned by the fd, and the entry identity plus link count are
//!   verified immediately before and after the call. A same-user racer can
//!   still swap the entry inside that tiny window; the post-checks detect it
//!   (nlink/identity mismatch) and report failure instead of success, and a
//!   swapped-in symlink is trashed as the link itself, never its target.
//! - Trash metadata records the /proc anchor path; a best-effort, identity
//!   verified repair rewrites Path= to the real display path so trash restore
//!   keeps working. If the repair cannot run, the file is still safely in the
//!   trash with the anchor path recorded.
//! - Create previews pin the parent directory's full identity (including
//!   mtime/size), so any concurrent change in the parent invalidates the
//!   approval (fail closed).
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("giounix2");
const linux = std.os.linux;

pub const max_matches = 20;
pub const max_search_entries = 4096;
pub const max_search_depth = 16;
pub const search_timeout_us: i64 = 2 * std.time.us_per_s;
pub const max_search_bytes: u64 = 8 * 1024 * 1024;
pub const max_read_size: u64 = 1024 * 1024;
pub const max_read_length: u64 = 16384;
pub const default_read_length: u64 = 4096;
pub const max_create_bytes = 32768;
pub const max_handles = 1024;
pub const max_args_bytes = 65536;
pub const max_query_bytes = 256;

// Raw flag values verified against /usr/include/bits/openat2.h and
// asm-generic fcntl constants on the target host (x86_64 Linux).
const O_RDONLY: u64 = 0;
const O_WRONLY: u64 = 1;
const O_CREAT: u64 = 0o100;
const O_EXCL: u64 = 0o200;
const O_TRUNC: u64 = 0o1000;
const O_NONBLOCK: u64 = 0o4000;
const O_DIRECTORY: u64 = 0o200000;
const O_NOFOLLOW: u64 = 0o400000;
const O_CLOEXEC: u64 = 0o2000000;
const RESOLVE_NO_XDEV: u64 = 0x01;
const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;
// Grant roots are absolute paths opened from CWD: BENEATH would anchor at the
// CWD and NO_XDEV would refuse legitimate mount crossings (e.g. a separate
// /home). Everything below a root uses the strict child resolution set.
const resolve_root: u64 = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
const resolve_child: u64 = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV;

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };

fn openat2(dirfd: c_int, path: [*:0]const u8, how: *const OpenHow) anyerror!c_int {
    const rc = linux.syscall4(.openat2, @bitCast(@as(i64, dirfd)), @intFromPtr(path), @intFromPtr(how), @sizeOf(OpenHow));
    const e = linux.errno(rc);
    if (e == .SUCCESS) return @intCast(rc);
    // Fail closed when the resolver is unavailable or rejects the flags;
    // never fall back to openat, which cannot enforce BENEATH/NO_SYMLINKS.
    if (e == .NOSYS or e == .INVAL or e == .@"2BIG") return error.ResolverUnsupported;
    return errnoError(e);
}

fn errnoError(e: linux.E) anyerror {
    return switch (e) {
        .NOENT => error.NotFound,
        .ACCES, .PERM => error.PermissionDenied,
        .EXIST => error.AlreadyExists,
        .NOTDIR => error.NotDirectory,
        .ISDIR => error.IsDirectory,
        .LOOP => error.SymlinkRejected,
        .XDEV => error.CrossedMount,
        .NAMETOOLONG => error.NameTooLong,
        .FBIG => error.FileTooLarge,
        .NOSPC, .DQUOT => error.NoSpace,
        .ROFS => error.ReadOnlyFilesystem,
        .BADF => error.HandleStale,
        else => error.OpenFailed,
    };
}

fn closeFd(fd: c_int) void {
    if (fd >= 0) _ = linux.close(fd);
}

const Stat = struct {
    mode: u16 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    size: u64 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: i64 = 0,
    nlink: u32 = 0,
    fn isReg(self: Stat) bool {
        return self.mode & linux.S.IFMT == linux.S.IFREG;
    }
    fn isDir(self: Stat) bool {
        return self.mode & linux.S.IFMT == linux.S.IFDIR;
    }
    fn sameFile(self: Stat, other: Stat) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

const statx_mask: linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .MTIME = true, .NLINK = true };

fn statToStat(stx: *const linux.Statx) Stat {
    return .{
        .mode = stx.mode,
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .ino = stx.ino,
        .size = stx.size,
        .mtime_sec = stx.mtime.sec,
        .mtime_nsec = stx.mtime.nsec,
        .nlink = stx.nlink,
    };
}

fn statFd(fd: c_int) anyerror!Stat {
    var stx: linux.Statx = undefined;
    const e = linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, statx_mask, &stx));
    if (e != .SUCCESS) return errnoError(e);
    return statToStat(&stx);
}

fn statAt(dirfd: c_int, name: [*:0]const u8, nofollow: bool) anyerror!Stat {
    var stx: linux.Statx = undefined;
    const flags: u32 = if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0;
    const e = linux.errno(linux.statx(dirfd, name, flags, statx_mask, &stx));
    if (e != .SUCCESS) return errnoError(e);
    return statToStat(&stx);
}

/// Host-owned identity snapshot shown in approval previews. sameHandle is the
/// exact revalidation predicate: path is display-only and never compared.
pub const Resource = struct {
    path: []const u8,
    dev: u64,
    ino: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    pub fn sameHandle(a: Resource, b: Resource) bool {
        return a.dev == b.dev and a.ino == b.ino and a.size == b.size and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec;
    }
};

fn resourceFrom(path: []const u8, st: Stat) Resource {
    return .{ .path = path, .dev = st.dev, .ino = st.ino, .size = st.size, .mtime_sec = st.mtime_sec, .mtime_nsec = st.mtime_nsec };
}

/// Grant-relative location used by resource(); never a model-supplied path.
pub const Handle = struct { grant_id: []const u8, path: []const u8 };

pub const ActionPreview = struct {
    kind: enum { create_file, delete_file, delete_file_permanent },
    target_path: []const u8,
    content: []const u8 = "",
    bytes: usize,
    /// create_file: identity of the parent directory that must remain
    /// unchanged. delete_*: identity of the exact file approved for removal.
    resource: Resource,
};

/// Controller-facing boundary pair, mirroring controller.Tools' opaque shape.
pub const LocalTools = struct {
    context: *anyopaque,
    dispatch: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, *gio.Cancellable) anyerror![]const u8,
};

/// Executor-side mirror of the config.Local shape the host adds. init()
/// accepts any structurally compatible value (including config.Local), so this
/// module compiles before and after that config change.
pub const FolderGrant = struct {
    id: []const u8,
    path: []const u8,
    read: bool = false,
    create: bool = false,
    delete: bool = false,
};
pub const LocalConfig = struct {
    enabled: bool = false,
    open_apps: bool = false,
    roots: []const FolderGrant = &.{},
};

const protected_prefixes = [_][]const u8{
    "/etc", "/usr",  "/bin", "/sbin", "/lib",  "/lib32",   "/lib64",   "/boot",
    "/dev", "/proc", "/sys", "/run",  "/root", "/var/lib", "/var/log", "/var/spool",
};
const protected_components = [_][]const u8{
    "autostart", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".pki", ".password-store", ".config", "keyrings", "credentials",
};
const sensitive_dirs = [_][]const u8{
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".pki", ".password-store", ".config", ".docker", "keyrings", "credentials", "secrets", "passwords",
};
const sensitive_files = [_][]const u8{
    ".netrc", ".env", ".git-credentials", ".npmrc", ".pypirc", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "secrets",
};
const sensitive_extensions = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore" };
const protected_names = [_][]const u8{
    ".bashrc",  ".bash_profile", ".bash_login", ".bash_logout",    ".profile",         ".zshrc",      ".zprofile", ".zshenv", ".zlogin",  ".zlogout",
    ".inputrc", ".netrc",        ".env",        ".gitconfig",      ".gitmodules",      ".curlrc",     ".wgetrc",   ".npmrc",  ".pypirc",  ".gemrc",
    ".xinitrc", ".xsession",     ".xsessionrc", "authorized_keys", "authorized_keys2", "known_hosts", "id_rsa",    "id_dsa",  "id_ecdsa", "id_ed25519",
};
const protected_extensions = [_][]const u8{
    ".desktop", ".directory", ".sh",     ".bash",   ".zsh",         ".fish",      ".ksh",  ".csh",    ".tcsh",
    ".exe",     ".dll",       ".so",     ".elf",    ".bin",         ".bat",       ".cmd",  ".com",    ".scr",
    ".pif",     ".msi",       ".msp",    ".gadget", ".application", ".appimage",  ".deb",  ".rpm",    ".jar",
    ".war",     ".service",   ".socket", ".timer",  ".mount",       ".automount", ".path", ".target", ".swap",
    ".slice",
};
const temp_prefix = ".pearl-tmp-";

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

fn hasControl(value: []const u8) bool {
    for (value) |ch| if (ch < 32 or ch == 127) return true;
    return false;
}

fn protectedComponent(part: []const u8) bool {
    for (protected_components) |p| if (std.ascii.eqlIgnoreCase(part, p)) return true;
    return false;
}

fn validateRootPath(path: []const u8) anyerror!void {
    if (path.len == 0 or path.len > 4096) return error.InvalidGrantPath;
    if (!std.unicode.utf8ValidateSlice(path) or hasControl(path)) return error.InvalidGrantPath;
    if (path[0] != '/') return error.AbsoluteGrantPathRequired;
    if (std.mem.eql(u8, path, "/")) return error.ProtectedGrantPath;
    if (path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null) return error.InvalidGrantPath;
    // /dev/shm is the user-writable temporary tmpfs, not a device directory;
    // it is a legitimate grant root (and the only unprivileged system-internal
    // mount, where trash is unsupported). The rest of /dev stays protected.
    const shm = std.mem.eql(u8, path, "/dev/shm") or std.mem.startsWith(u8, path, "/dev/shm/");
    if (!shm) {
        for (protected_prefixes) |p| {
            if (std.mem.startsWith(u8, path, p) and (path.len == p.len or path[p.len] == '/')) return error.ProtectedGrantPath;
        }
    }
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGrantPath;
        if (protectedComponent(part)) return error.ProtectedGrantPath;
    }
}

fn validateGrant(g: anytype) anyerror!void {
    if (!validId(g.id)) return error.InvalidGrantId;
    try validateRootPath(g.path);
}

/// Single-component name rules for create_file. Protected names cover
/// launchers, shell scripts, executables, shell/config dotfiles and keys.
fn validNewName(name: []const u8) anyerror!void {
    if (name.len == 0 or name.len > 255) return error.InvalidName;
    if (!std.unicode.utf8ValidateSlice(name) or hasControl(name)) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidName;
    if (std.mem.startsWith(u8, name, temp_prefix)) return error.InvalidName;
    for (protected_names) |p| if (std.ascii.eqlIgnoreCase(name, p)) return error.ProtectedName;
    for (protected_extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return error.ProtectedName;
    if (std.mem.startsWith(u8, name, "#!")) return error.ProtectedName;
}

fn protectedContent(content: []const u8) bool {
    if (std.mem.startsWith(u8, content, "#!")) return true;
    if (std.mem.startsWith(u8, content, "\x7fELF")) return true;
    return false;
}

fn sensitiveDirName(name: []const u8) bool {
    for (sensitive_dirs) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

fn sensitiveFileName(name: []const u8) bool {
    for (sensitive_files) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    for (sensitive_extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

fn containsSensitiveComponent(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "autostart") or protectedComponent(part)) return true;
    }
    return false;
}

const Grant = struct {
    id: []const u8,
    path: []const u8,
    read: bool,
    create: bool,
    delete: bool,
    fd: c_int = -1,
    stat: Stat = .{},
};

const Entry = struct {
    grant: usize,
    /// Files: held-open fd of the containing directory. Directories: held-open
    /// fd of the directory itself. Keeping the fd open pins the inode so its
    /// dev/ino identity cannot be recycled while a handle is live.
    fd: c_int,
    name: [:0]u8,
    rel: []const u8,
    stat: Stat,
    is_dir: bool,
};

const SearchArgs = struct {
    root_id: []const u8 = "",
    query: []const u8 = "",
    mode: []const u8 = "filename",
    cursor: ?u64 = null,
};
const ReadArgs = struct {
    file_id: []const u8 = "",
    offset: u64 = 0,
    length: u64 = default_read_length,
};
const CreateArgs = struct {
    parent_id: []const u8 = "",
    name: []const u8 = "",
    content: []const u8 = "",
};
const DeleteArgs = struct { file_id: []const u8 = "" };

pub const Tools = struct {
    a: std.mem.Allocator,
    enabled: bool,
    grants: []Grant,
    handles: std.StringHashMapUnmanaged(Entry) = .{},
    order: std.ArrayListUnmanaged([]const u8) = .empty,
    next_id: u64 = 0,

    /// Accepts config.Local (host) or files.LocalConfig (tests); the field
    /// shape is checked structurally at compile time.
    pub fn init(a: std.mem.Allocator, local: anytype) !Tools {
        var grants: std.ArrayList(Grant) = .empty;
        errdefer {
            for (grants.items) |g| {
                closeFd(g.fd);
                a.free(g.id);
                a.free(g.path);
            }
            grants.deinit(a);
        }
        for (local.roots) |root| {
            try validateGrant(root);
            for (grants.items) |other| {
                if (std.mem.eql(u8, other.id, root.id)) return error.DuplicateGrant;
                if (std.mem.eql(u8, other.path, root.path)) return error.DuplicateGrant;
            }
            const id = try a.dupe(u8, root.id);
            errdefer a.free(id);
            const path = try a.dupe(u8, root.path);
            errdefer a.free(path);
            var g = Grant{ .id = id, .path = path, .read = root.read, .create = root.create, .delete = root.delete };
            if (local.enabled) {
                const z = try a.dupeSentinel(u8, path, 0);
                defer a.free(z);
                const how = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_root };
                if (openat2(linux.AT.FDCWD, z, &how)) |fd| {
                    g.fd = fd;
                    g.stat = statFd(fd) catch .{};
                } else |_| {
                    // A missing/unreadable root stays unavailable; operations
                    // on it fail closed without breaking other grants.
                }
            }
            try grants.append(a, g);
        }
        return .{ .a = a, .enabled = local.enabled, .grants = try grants.toOwnedSlice(a) };
    }

    pub fn deinit(self: *Tools) void {
        var it = self.handles.iterator();
        while (it.next()) |kv| {
            closeFd(kv.value_ptr.fd);
            self.a.free(kv.value_ptr.name);
            self.a.free(kv.value_ptr.rel);
            self.a.free(kv.key_ptr.*);
        }
        self.handles.deinit(self.a);
        self.order.deinit(self.a);
        for (self.grants) |g| {
            closeFd(g.fd);
            self.a.free(g.id);
            self.a.free(g.path);
        }
        self.a.free(self.grants);
        self.* = undefined;
    }

    /// Null when local files are disabled, so the host can withhold the tools.
    pub fn tools(self: *Tools) ?LocalTools {
        if (!self.enabled) return null;
        return .{ .context = self, .dispatch = dispatchEntry };
    }

    fn dispatchEntry(ctx: *anyopaque, a: std.mem.Allocator, name: []const u8, args: []const u8, cancel: *gio.Cancellable) anyerror![]const u8 {
        const self: *Tools = @ptrCast(@alignCast(ctx));
        return self.dispatch(a, name, args, cancel);
    }

    /// Model-facing entry point. Read-only tools execute directly; mutations
    /// are denied here because they require the host's prepare/approve/execute
    /// flow. Cancellation and OOM propagate; everything else becomes JSON.
    pub fn dispatch(self: *Tools, a: std.mem.Allocator, name: []const u8, args: []const u8, cancel: *gio.Cancellable) anyerror![]const u8 {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (!self.enabled) return denyJson(a, error.LocalFilesDisabled);
        if (args.len > max_args_bytes) return failJson(a, error.InvalidToolCall);
        if (std.mem.eql(u8, name, "search_files")) {
            return self.searchFiles(a, args, cancel) catch |err| jsonForError(a, err);
        }
        if (std.mem.eql(u8, name, "read_file")) {
            return self.readFile(a, args, cancel) catch |err| jsonForError(a, err);
        }
        if (std.mem.eql(u8, name, "create_file") or std.mem.eql(u8, name, "delete_file")) {
            return denyJson(a, error.ApprovalRequired);
        }
        return failJson(a, error.UnknownTool);
    }

    /// Produce the exact, side-effect-free approval preview for a mutation.
    pub fn prepare(self: *Tools, a: std.mem.Allocator, name: []const u8, args: []const u8, cancel: *gio.Cancellable) !ActionPreview {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (!self.enabled) return error.LocalFilesDisabled;
        if (args.len > max_args_bytes) return error.InvalidToolCall;
        if (std.mem.eql(u8, name, "create_file")) return self.prepareCreate(a, args, cancel);
        if (std.mem.eql(u8, name, "delete_file")) return self.prepareDelete(a, args, cancel);
        return error.UnknownTool;
    }

    /// Execute a tool call. Mutations require the approved preview and
    /// revalidate its identity; read-only tools ignore the preview.
    pub fn execute(self: *Tools, a: std.mem.Allocator, name: []const u8, args: []const u8, preview: ?ActionPreview, cancel: *gio.Cancellable) ![]const u8 {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (!self.enabled) return error.LocalFilesDisabled;
        if (args.len > max_args_bytes) return error.InvalidToolCall;
        if (std.mem.eql(u8, name, "search_files")) return self.searchFiles(a, args, cancel);
        if (std.mem.eql(u8, name, "read_file")) return self.readFile(a, args, cancel);
        if (std.mem.eql(u8, name, "create_file")) {
            const p = preview orelse return error.ApprovalRequired;
            if (p.kind != .create_file) return error.InvalidPreview;
            return self.executeCreate(a, args, p, cancel);
        }
        if (std.mem.eql(u8, name, "delete_file")) {
            const p = preview orelse return error.ApprovalRequired;
            if (p.kind != .delete_file and p.kind != .delete_file_permanent) return error.InvalidPreview;
            return self.executeDelete(a, args, p, cancel);
        }
        return error.UnknownTool;
    }

    /// Stat a grant-relative path for the host UI without minting a handle.
    pub fn resource(self: *Tools, a: std.mem.Allocator, handle: Handle, cancel: *gio.Cancellable) !Resource {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (!self.enabled) return error.LocalFilesDisabled;
        const gi = self.grantIndex(handle.grant_id) orelse return error.UnknownRoot;
        const g = &self.grants[gi];
        if (!g.read) return error.PermissionDenied;
        try self.checkRoot(g, cancel);
        if (handle.path.len > 4096 or !std.unicode.utf8ValidateSlice(handle.path) or hasControl(handle.path)) return error.InvalidGrantPath;
        const fd = try self.resolveRel(g, handle.path, cancel);
        defer closeFd(fd);
        const st = try statFd(fd);
        const abs = try joinPath(a, g.path, handle.path);
        return resourceFrom(abs, st);
    }

    // ---- grants and handles ------------------------------------------------

    fn grantIndex(self: *Tools, id: []const u8) ?usize {
        for (self.grants, 0..) |g, i| if (std.mem.eql(u8, g.id, id)) return i;
        return null;
    }

    /// Re-open the configured root path and verify it still resolves to the
    /// identity pinned at init; detects root substitution or relocation.
    fn checkRoot(self: *Tools, g: *const Grant, cancel: *gio.Cancellable) anyerror!void {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (g.fd < 0) return error.GrantUnavailable;
        const z = try self.a.dupeSentinel(u8, g.path, 0);
        defer self.a.free(z);
        const how = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_root };
        const fd = try openat2(linux.AT.FDCWD, z, &how);
        defer closeFd(fd);
        const st = try statFd(fd);
        if (!st.sameFile(g.stat)) return error.GrantChanged;
    }

    /// Walk a grant-relative path from the pinned root fd with strict
    /// per-component resolution. Returns a fresh fd the caller must close.
    fn resolveRel(self: *Tools, g: *const Grant, rel: []const u8, cancel: *gio.Cancellable) anyerror!c_int {
        if (rel.len > 4096 or !std.unicode.utf8ValidateSlice(rel) or hasControl(rel)) return error.InvalidGrantPath;
        if (rel.len == 0) {
            const how = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, .mode = 0, .resolve = resolve_child };
            return try openat2(g.fd, ".", &how);
        }
        var cur = g.fd;
        var owned = false;
        errdefer if (owned) closeFd(cur);
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |part| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGrantPath;
            const last = it.peek() == null;
            const z = try self.a.dupeSentinel(u8, part, 0);
            defer self.a.free(z);
            var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW;
            // Only intermediate components must be directories; the final
            // component's type is verified by the caller's identity check.
            if (!last) flags |= O_DIRECTORY;
            const how = OpenHow{ .flags = flags, .mode = 0, .resolve = resolve_child };
            const next = try openat2(cur, z, &how);
            if (owned) closeFd(cur);
            cur = next;
            owned = true;
        }
        return cur;
    }

    fn entryParentRel(entry: *const Entry) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, entry.rel, '/')) |i| return entry.rel[0..i];
        return "";
    }

    /// Re-resolve a handle from the grant root and verify the held fd still
    /// matches the path's identity. Returns the grant; the held fd stays owned
    /// by the entry and is used for the actual operation.
    fn verifyEntry(self: *Tools, entry: *const Entry, cancel: *gio.Cancellable) anyerror!*const Grant {
        const g = &self.grants[entry.grant];
        try self.checkRoot(g, cancel);
        const held = try statFd(entry.fd);
        if (entry.is_dir) {
            const fd = try self.resolveRel(g, entry.rel, cancel);
            defer closeFd(fd);
            const st = try statFd(fd);
            if (!st.sameFile(held)) return error.HandleStale;
        } else {
            const fd = try self.resolveRel(g, entryParentRel(entry), cancel);
            defer closeFd(fd);
            const st = try statFd(fd);
            if (!st.sameFile(held)) return error.HandleStale;
        }
        return g;
    }

    fn lookupEntry(self: *Tools, id: []const u8) ?*Entry {
        return self.handles.getPtr(id);
    }

    fn newId(self: *Tools, a: std.mem.Allocator) ![:0]u8 {
        var rnd: [8]u8 = undefined;
        const e = linux.errno(linux.getrandom(&rnd, rnd.len, 0));
        if (e != .SUCCESS) return error.RandomUnavailable;
        self.next_id += 1;
        return std.fmt.allocPrintSentinel(a, "h{d}-{s}", .{ self.next_id, std.fmt.bytesToHex(rnd, .lower) }, 0);
    }

    fn putHandle(self: *Tools, entry: Entry) ![:0]u8 {
        while (self.order.items.len >= max_handles) {
            const oldest = self.order.orderedRemove(0);
            if (self.handles.fetchRemove(oldest)) |kv| {
                closeFd(kv.value.fd);
                self.a.free(kv.value.name);
                self.a.free(kv.value.rel);
            }
            self.a.free(oldest);
        }
        const id = try self.newId(self.a);
        errdefer self.a.free(id);
        try self.handles.put(self.a, id, entry);
        errdefer _ = self.handles.remove(id);
        try self.order.append(self.a, id);
        return id;
    }

    fn removeHandle(self: *Tools, id: []const u8) void {
        if (self.handles.fetchRemove(id)) |kv| {
            closeFd(kv.value.fd);
            self.a.free(kv.value.name);
            self.a.free(kv.value.rel);
            self.a.free(kv.key);
            for (self.order.items, 0..) |oid, i| {
                if (std.mem.eql(u8, oid, id)) {
                    _ = self.order.orderedRemove(i);
                    break;
                }
            }
        }
    }

    // ---- search --------------------------------------------------------------

    const Match = struct {
        file_id: []const u8,
        name: []const u8,
        path: []const u8,
        root_path: []const u8,
        type: []const u8,
        size: u64,
        mtime_sec: i64,
    };

    const Walk = struct {
        self: *Tools,
        a: std.mem.Allocator,
        grant: usize,
        root_path: []const u8,
        root_dev: u64,
        query: []const u8,
        content_mode: bool,
        cursor: u64,
        deadline: i64,
        visited: u64 = 0,
        skipped: u64 = 0,
        content_bytes: u64 = 0,
        truncated: bool = false,
        stopped: bool = false,
        next_cursor: ?u64 = null,
        matches: std.ArrayList(Match) = .empty,
        cancel: *gio.Cancellable,

        fn budgetHit(w: *Walk) bool {
            if (w.cancel.isCancelled() != 0) return true;
            if (w.visited >= max_search_entries) return true;
            if (glib.getMonotonicTime() > w.deadline) return true;
            if (w.content_mode and w.content_bytes >= max_search_bytes) return true;
            return false;
        }
    };

    fn searchFiles(self: *Tools, a: std.mem.Allocator, args: []const u8, cancel: *gio.Cancellable) anyerror![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(SearchArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        if (parsed.query.len == 0 or parsed.query.len > max_query_bytes) return error.InvalidToolCall;
        if (!std.unicode.utf8ValidateSlice(parsed.query) or hasControl(parsed.query)) return error.InvalidToolCall;
        const content_mode = if (std.mem.eql(u8, parsed.mode, "filename")) false else if (std.mem.eql(u8, parsed.mode, "content")) true else return error.InvalidToolCall;
        if ((parsed.cursor orelse 0) >= max_search_entries) {
            // A single call can never visit past the entry budget, so such a
            // cursor is exhausted; report completion instead of looping.
            return std.json.Stringify.valueAlloc(a, .{
                .status = "ok",
                .root_id = parsed.root_id,
                .query = parsed.query,
                .mode = parsed.mode,
                .matches = @as([]const Match, &.{}),
                .cursor = @as(?u64, null),
                .truncated = true,
                .skipped = @as(u64, 0),
                .visited = @as(u64, 0),
                .message = "The search budget cannot reach this cursor. Narrow the query or search a subfolder.",
            }, .{});
        }
        if (parsed.root_id.len == 0) {
            var roots: std.ArrayList([]const u8) = .empty;
            for (self.grants) |g| if (g.read and g.fd >= 0) try roots.append(a, g.id);
            if (roots.items.len == 0) return error.PermissionDenied;
            return std.json.Stringify.valueAlloc(a, .{
                .status = "ambiguous",
                .@"error" = "AmbiguousRoot",
                .roots = roots.items,
                .message = "Several folder grants are readable. Call search_files again with one root_id from roots.",
            }, .{});
        }
        var root_fd: c_int = undefined;
        var base_rel: []const u8 = "";
        var gi: usize = undefined;
        if (std.mem.startsWith(u8, parsed.root_id, "root:")) {
            gi = self.grantIndex(parsed.root_id[5..]) orelse return error.UnknownRoot;
            const g = &self.grants[gi];
            if (!g.read) return error.PermissionDenied;
            try self.checkRoot(g, cancel);
            root_fd = g.fd;
        } else {
            const entry = self.lookupEntry(parsed.root_id) orelse return error.UnknownHandle;
            if (!entry.is_dir) return error.NotDirectory;
            const g = try self.verifyEntry(entry, cancel);
            if (!g.read) return error.PermissionDenied;
            gi = entry.grant;
            root_fd = entry.fd;
            // The walk may evict this very handle; copy the display base.
            base_rel = try a.dupe(u8, entry.rel);
        }
        const g = &self.grants[gi];
        // The walk opens its own directory description (fresh offset) so
        // handle eviction and repeated pagination cannot disturb it.
        const walk_how = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, .mode = 0, .resolve = resolve_child };
        const walk_fd = try openat2(root_fd, ".", &walk_how);
        defer closeFd(walk_fd);
        const root_stat = try statFd(walk_fd);
        var walk = Walk{
            .self = self,
            .a = a,
            .grant = gi,
            .root_path = g.path,
            .root_dev = root_stat.dev,
            .query = parsed.query,
            .content_mode = content_mode,
            .cursor = parsed.cursor orelse 0,
            .deadline = glib.getMonotonicTime() + search_timeout_us,
            .cancel = cancel,
        };
        defer walk.matches.deinit(a);
        try self.walkDir(&walk, walk_fd, base_rel, 0);
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (walk.truncated and walk.next_cursor == null) walk.next_cursor = walk.visited;
        return std.json.Stringify.valueAlloc(a, .{
            .status = "ok",
            .root_id = parsed.root_id,
            .query = parsed.query,
            .mode = parsed.mode,
            .matches = walk.matches.items,
            .cursor = walk.next_cursor,
            .truncated = walk.truncated,
            .skipped = walk.skipped,
            .visited = walk.visited,
            .message = if (walk.truncated) "Search budgets were reached; results may be incomplete. Narrow the query or search a subfolder." else "",
        }, .{});
    }

    const DirEnt = struct { name: [:0]u8, kind: u8 };

    fn walkDir(self: *Tools, w: *Walk, dirfd: c_int, rel: []const u8, depth: usize) anyerror!void {
        if (w.stopped) return;
        if (w.budgetHit()) {
            w.truncated = true;
            w.stopped = true;
            w.next_cursor = w.visited;
            return;
        }
        var names: std.ArrayList(DirEnt) = .empty;
        defer {
            for (names.items) |ent| w.a.free(ent.name);
            names.deinit(w.a);
        }
        var buf: [8192]u8 align(8) = undefined;
        while (true) {
            if (w.budgetHit() or names.items.len >= max_search_entries) {
                w.truncated = true;
                break;
            }
            const n = linux.getdents64(dirfd, &buf, buf.len);
            const e = linux.errno(n);
            if (e != .SUCCESS) {
                w.skipped += 1;
                return;
            }
            if (n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const dent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
                off += dent.reclen;
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&dent.name)), 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (names.items.len >= max_search_entries) {
                    w.truncated = true;
                    break;
                }
                try names.append(w.a, .{ .name = try w.a.dupeSentinel(u8, name, 0), .kind = dent.type });
            }
            if (w.truncated) break;
        }
        std.mem.sort(DirEnt, names.items, {}, struct {
            fn lt(_: void, x: DirEnt, y: DirEnt) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        for (names.items) |ent| {
            if (w.stopped) return;
            if (w.budgetHit()) {
                w.truncated = true;
                w.stopped = true;
                w.next_cursor = w.visited;
                return;
            }
            const index = w.visited;
            w.visited += 1;
            const name = ent.name;
            if (name.len == 0 or name[0] == '.' or !std.unicode.utf8ValidateSlice(name) or sensitiveDirName(name)) {
                w.skipped += 1;
                continue;
            }
            if (ent.kind == linux.DT.LNK or ent.kind == linux.DT.FIFO or ent.kind == linux.DT.CHR or ent.kind == linux.DT.BLK or ent.kind == linux.DT.SOCK or ent.kind == linux.DT.WHT) {
                w.skipped += 1;
                continue;
            }
            var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW;
            if (ent.kind == linux.DT.DIR) flags |= O_DIRECTORY;
            const how = OpenHow{ .flags = flags, .mode = 0, .resolve = resolve_child };
            const child = openat2(dirfd, name, &how) catch {
                w.skipped += 1;
                continue;
            };
            var child_owned = true;
            defer if (child_owned) closeFd(child);
            const st = statFd(child) catch {
                w.skipped += 1;
                continue;
            };
            if (st.dev != w.root_dev or (!st.isReg() and !st.isDir())) {
                w.skipped += 1;
                continue;
            }
            const child_rel = try joinPath(w.a, rel, name);
            if (st.isDir()) {
                if (!w.content_mode and std.ascii.findIgnoreCase(name, w.query) != null) {
                    if (try emitDir(w, child, child_rel, name, st, index)) child_owned = false;
                    if (w.stopped) return;
                }
                if (depth + 1 < max_search_depth) {
                    // A fresh directory description keeps the walk independent
                    // of handle lifetimes and of any shared seek offset.
                    const descent_how = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, .mode = 0, .resolve = resolve_child };
                    if (openat2(child, ".", &descent_how)) |descent| {
                        defer closeFd(descent);
                        try self.walkDir(w, descent, child_rel, depth + 1);
                    } else |_| {
                        w.skipped += 1;
                    }
                } else {
                    w.truncated = true;
                }
            } else {
                if (sensitiveFileName(name)) {
                    w.skipped += 1;
                    continue;
                }
                const matched = if (w.content_mode)
                    try self.contentMatch(w, child, st)
                else
                    std.ascii.findIgnoreCase(name, w.query) != null;
                if (matched) try emitFile(w, dirfd, child_rel, name, st, index);
            }
        }
    }

    fn contentMatch(self: *Tools, w: *Walk, fd: c_int, st: Stat) anyerror!bool {
        _ = self;
        if (st.size == 0) return false;
        if (st.size > max_read_size) {
            w.skipped += 1;
            return false;
        }
        const remaining = max_search_bytes - w.content_bytes;
        if (remaining == 0) {
            w.truncated = true;
            w.stopped = true;
            w.next_cursor = w.visited;
            return false;
        }
        const want: usize = @intCast(@min(st.size, remaining));
        const buf = try w.a.alloc(u8, want);
        defer w.a.free(buf);
        const n = try readFull(fd, buf, 0);
        w.content_bytes += n;
        const sniff = @min(n, 8192);
        if (std.mem.indexOfScalar(u8, buf[0..sniff], 0) != null) {
            w.skipped += 1;
            return false;
        }
        return std.ascii.findIgnoreCase(buf[0..n], w.query) != null;
    }

    fn emitFile(w: *Walk, dirfd: c_int, rel: []const u8, name: [:0]u8, st: Stat, index: u64) anyerror!void {
        if (index < w.cursor or w.matches.items.len >= max_matches) return;
        // All fallible work happens before ownership transfers to the handle;
        // afterwards only infallible stores remain, so error paths cannot free
        // or close resources a live handle already owns.
        const slot = try w.matches.addOne(w.a);
        const match_name = try w.a.dupe(u8, name);
        const entry_name = try w.self.a.dupeSentinel(u8, name, 0);
        var entry_name_live = true;
        errdefer if (entry_name_live) w.self.a.free(entry_name);
        const rel_owned = try w.self.a.dupe(u8, rel);
        var rel_live = true;
        errdefer if (rel_live) w.self.a.free(rel_owned);
        const parent = linux.dup(dirfd);
        if (linux.errno(parent) != .SUCCESS) {
            w.self.a.free(entry_name);
            entry_name_live = false;
            w.self.a.free(rel_owned);
            rel_live = false;
            w.skipped += 1;
            return;
        }
        const id = w.self.putHandle(.{
            .grant = w.grant,
            .fd = @intCast(parent),
            .name = entry_name,
            .rel = rel_owned,
            .stat = st,
            .is_dir = false,
        }) catch {
            closeFd(@intCast(parent));
            w.self.a.free(entry_name);
            entry_name_live = false;
            w.self.a.free(rel_owned);
            rel_live = false;
            w.skipped += 1;
            return;
        };
        entry_name_live = false;
        rel_live = false;
        slot.* = .{
            .file_id = id,
            .name = match_name,
            .path = rel,
            .root_path = w.root_path,
            .type = "file",
            .size = st.size,
            .mtime_sec = st.mtime_sec,
        };
        if (w.matches.items.len >= max_matches) {
            w.stopped = true;
            w.next_cursor = index + 1;
        }
    }

    /// Returns true when the directory fd ownership transferred to a handle.
    fn emitDir(w: *Walk, fd: c_int, rel: []const u8, name: [:0]u8, st: Stat, index: u64) anyerror!bool {
        if (index < w.cursor or w.matches.items.len >= max_matches) return false;
        const slot = try w.matches.addOne(w.a);
        const match_name = try w.a.dupe(u8, name);
        const entry_name = try w.self.a.dupeSentinel(u8, name, 0);
        var entry_name_live = true;
        errdefer if (entry_name_live) w.self.a.free(entry_name);
        const rel_owned = try w.self.a.dupe(u8, rel);
        var rel_live = true;
        errdefer if (rel_live) w.self.a.free(rel_owned);
        const id = w.self.putHandle(.{
            .grant = w.grant,
            .fd = fd,
            .name = entry_name,
            .rel = rel_owned,
            .stat = st,
            .is_dir = true,
        }) catch {
            w.self.a.free(entry_name);
            entry_name_live = false;
            w.self.a.free(rel_owned);
            rel_live = false;
            w.skipped += 1;
            return false;
        };
        entry_name_live = false;
        rel_live = false;
        slot.* = .{
            .file_id = id,
            .name = match_name,
            .path = rel,
            .root_path = w.root_path,
            .type = "directory",
            .size = st.size,
            .mtime_sec = st.mtime_sec,
        };
        if (w.matches.items.len >= max_matches) {
            w.stopped = true;
            w.next_cursor = index + 1;
        }
        return true;
    }

    // ---- read ----------------------------------------------------------------

    fn readFile(self: *Tools, a: std.mem.Allocator, args: []const u8, cancel: *gio.Cancellable) anyerror![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(ReadArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        if (parsed.file_id.len == 0 or parsed.file_id.len > 128) return error.InvalidToolCall;
        const entry = self.lookupEntry(parsed.file_id) orelse return error.UnknownHandle;
        if (entry.is_dir) return error.IsDirectory;
        const g = try self.verifyEntry(entry, cancel);
        if (!g.read) return error.PermissionDenied;
        if (sensitiveFileName(entry.name)) return error.PermissionDenied;
        const how = OpenHow{ .flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_child };
        const fd = try openat2(entry.fd, entry.name, &how);
        defer closeFd(fd);
        const st = try statFd(fd);
        if (!st.isReg()) return error.NotRegularFile;
        if (!st.sameFile(entry.stat)) return error.HandleStale;
        if (st.size > max_read_size) return error.FileTooLarge;
        const length = @min(parsed.length, max_read_length);
        if (parsed.offset >= st.size or length == 0) {
            return std.json.Stringify.valueAlloc(a, .{
                .status = "ok",
                .file_id = parsed.file_id,
                .offset = parsed.offset,
                .bytes = @as(usize, 0),
                .size = st.size,
                .content = "",
                .next_offset = @as(?u64, null),
                .truncated = false,
            }, .{});
        }
        // Read a small halo around the requested range so multi-byte UTF-8
        // characters split by offset/length can be completed, never cut.
        const lo = parsed.offset -| 3;
        const hi = @min(st.size, parsed.offset + length + 3);
        var buf: [max_read_length + 6]u8 = undefined;
        const n = try readFull(fd, buf[0..@intCast(hi - lo)], @intCast(lo));
        var s: usize = @intCast(parsed.offset - lo);
        var back: usize = 0;
        while (s > 0 and back < 3 and (buf[s] & 0xC0) == 0x80) : (back += 1) s -= 1;
        var e: usize = @intCast(@min(parsed.offset + length, hi) - lo);
        if (e > n) e = n;
        while (e < n and (buf[e] & 0xC0) == 0x80) e += 1;
        const slice = buf[s..e];
        if (std.mem.indexOfScalar(u8, slice, 0) != null) return error.BinaryFile;
        if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
        const actual_offset = lo + s;
        const next = lo + e;
        return std.json.Stringify.valueAlloc(a, .{
            .status = "ok",
            .file_id = parsed.file_id,
            .offset = actual_offset,
            .bytes = slice.len,
            .size = st.size,
            .content = slice,
            .next_offset = if (next < st.size) @as(?u64, next) else null,
            .truncated = next < st.size,
        }, .{});
    }

    fn readFull(fd: c_int, buf: []u8, offset: u64) anyerror!usize {
        var done: usize = 0;
        while (done < buf.len) {
            const rc = linux.pread(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return errnoError(e);
            if (rc == 0) break;
            done += rc;
        }
        return done;
    }

    // ---- create --------------------------------------------------------------

    const ParentRef = struct {
        gi: usize,
        fd: c_int,
        rel: []const u8,
        held: bool,
    };

    fn resolveParent(self: *Tools, parent_id: []const u8, cancel: *gio.Cancellable) anyerror!ParentRef {
        if (std.mem.startsWith(u8, parent_id, "root:")) {
            const gi = self.grantIndex(parent_id[5..]) orelse return error.UnknownRoot;
            const g = &self.grants[gi];
            if (!g.create) return error.PermissionDenied;
            try self.checkRoot(g, cancel);
            return .{ .gi = gi, .fd = g.fd, .rel = "", .held = false };
        }
        const entry = self.lookupEntry(parent_id) orelse return error.UnknownHandle;
        if (!entry.is_dir) return error.NotDirectory;
        const g = try self.verifyEntry(entry, cancel);
        if (!g.create) return error.PermissionDenied;
        return .{ .gi = entry.grant, .fd = entry.fd, .rel = entry.rel, .held = true };
    }

    fn prepareCreate(self: *Tools, a: std.mem.Allocator, args: []const u8, cancel: *gio.Cancellable) anyerror!ActionPreview {
        const parsed = std.json.parseFromSliceLeaky(CreateArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        try validNewName(parsed.name);
        if (parsed.content.len > max_create_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(parsed.content)) return error.InvalidUtf8;
        for (parsed.content) |ch| if (ch < 32 and ch != '\t' and ch != '\n' and ch != '\r') return error.InvalidToolCall;
        if (protectedContent(parsed.content)) return error.ProtectedName;
        const parent = try self.resolveParent(parsed.parent_id, cancel);
        const g = &self.grants[parent.gi];
        if (containsSensitiveComponent(parent.rel)) return error.ProtectedPath;
        const namez = try a.dupeSentinel(u8, parsed.name, 0);
        defer a.free(namez);
        if (statAt(parent.fd, namez, true)) |_| {
            return error.AlreadyExists;
        } else |err| {
            if (err != error.NotFound) return err;
        }
        const st = try statFd(parent.fd);
        const parent_path = try joinPath(a, g.path, parent.rel);
        const target = try joinPath(a, parent_path, parsed.name);
        return .{
            .kind = .create_file,
            .target_path = target,
            .content = try a.dupe(u8, parsed.content),
            .bytes = parsed.content.len,
            .resource = resourceFrom(parent_path, st),
        };
    }

    fn executeCreate(self: *Tools, a: std.mem.Allocator, args: []const u8, preview: ActionPreview, cancel: *gio.Cancellable) anyerror![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(CreateArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        try validNewName(parsed.name);
        if (parsed.content.len > max_create_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(parsed.content)) return error.InvalidUtf8;
        for (parsed.content) |ch| if (ch < 32 and ch != '\t' and ch != '\n' and ch != '\r') return error.InvalidToolCall;
        if (protectedContent(parsed.content)) return error.ProtectedName;
        if (!std.mem.eql(u8, parsed.content, preview.content)) return error.StaleApproval;
        const parent = try self.resolveParent(parsed.parent_id, cancel);
        const g = &self.grants[parent.gi];
        if (containsSensitiveComponent(parent.rel)) return error.ProtectedPath;
        const parent_stat = try statFd(parent.fd);
        if (!Resource.sameHandle(resourceFrom("", parent_stat), preview.resource)) return error.StaleApproval;
        const namez = try a.dupeSentinel(u8, parsed.name, 0);
        defer a.free(namez);
        if (statAt(parent.fd, namez, true)) |_| {
            return error.AlreadyExists;
        } else |err| {
            if (err != error.NotFound) return err;
        }
        if (cancel.isCancelled() != 0) return error.Cancelled;
        // Exclusive temp sibling in the same parent, then RENAME_NOREPLACE:
        // no overwrite is possible even if the target appears mid-flight.
        var rnd: [8]u8 = undefined;
        if (linux.errno(linux.getrandom(&rnd, rnd.len, 0)) != .SUCCESS) return error.RandomUnavailable;
        const temp = try std.fmt.allocPrintSentinel(a, temp_prefix ++ "{s}", .{std.fmt.bytesToHex(rnd, .lower)}, 0);
        defer a.free(temp);
        const how = OpenHow{ .flags = O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, .mode = 0o600, .resolve = resolve_child };
        const fd = try openat2(parent.fd, temp, &how);
        var created = true;
        errdefer if (created) {
            _ = linux.unlinkat(parent.fd, temp, 0);
        };
        defer closeFd(fd);
        var done: usize = 0;
        while (done < parsed.content.len) {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const rc = linux.write(fd, parsed.content[done..].ptr, parsed.content.len - done);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return errnoError(e);
            if (rc == 0) return error.WriteFailed;
            done += rc;
        }
        if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.WriteFailed;
        const st = try statFd(fd);
        const rename_rc = linux.renameat2(parent.fd, temp, parent.fd, namez, .{ .NOREPLACE = true });
        const rename_e = linux.errno(rename_rc);
        if (rename_e == .NOSYS or rename_e == .INVAL) return error.RenameUnsupported;
        if (rename_e != .SUCCESS) return errnoError(rename_e);
        created = false;
        _ = linux.fsync(parent.fd); // best-effort directory durability
        const rel = try joinPath(self.a, parent.rel, parsed.name);
        const entry_name = try self.a.dupeSentinel(u8, parsed.name, 0);
        var registered = false;
        errdefer if (!registered) {
            self.a.free(entry_name);
            self.a.free(rel);
        };
        const parent_dup = linux.dup(parent.fd);
        if (linux.errno(parent_dup) != .SUCCESS) return error.OpenFailed;
        const id = self.putHandle(.{
            .grant = parent.gi,
            .fd = @intCast(parent_dup),
            .name = entry_name,
            .rel = rel,
            .stat = st,
            .is_dir = false,
        }) catch |err| {
            closeFd(@intCast(parent_dup));
            return err;
        };
        registered = true;
        const parent_path = try joinPath(a, g.path, parent.rel);
        return std.json.Stringify.valueAlloc(a, .{
            .status = "ok",
            .file_id = id,
            .name = parsed.name,
            .path = rel,
            .root_path = g.path,
            .target_path = try joinPath(a, parent_path, parsed.name),
            .bytes = parsed.content.len,
        }, .{});
    }

    // ---- delete --------------------------------------------------------------

    const DeleteTarget = struct {
        entry: *Entry,
        gi: usize,
        fd: c_int,
        st: Stat,
        abs: []const u8,
    };

    fn resolveDeleteTarget(self: *Tools, a: std.mem.Allocator, file_id: []const u8, cancel: *gio.Cancellable) anyerror!DeleteTarget {
        if (file_id.len == 0 or file_id.len > 128) return error.InvalidToolCall;
        const entry = self.lookupEntry(file_id) orelse return error.UnknownHandle;
        if (entry.is_dir) return error.DirectoriesNotSupported;
        const g = try self.verifyEntry(entry, cancel);
        if (!g.read or !g.delete) return error.PermissionDenied;
        if (sensitiveFileName(entry.name)) return error.PermissionDenied;
        const how = OpenHow{ .flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_child };
        const fd = try openat2(entry.fd, entry.name, &how);
        errdefer closeFd(fd);
        const st = try statFd(fd);
        if (!st.isReg()) return error.NotRegularFile;
        if (!st.sameFile(entry.stat)) return error.HandleStale;
        const entry_st = try statAt(entry.fd, entry.name, true);
        if (!entry_st.sameFile(st) or !entry_st.isReg()) return error.HandleStale;
        return .{ .entry = entry, .gi = entry.grant, .fd = fd, .st = st, .abs = try joinPath(a, g.path, entry.rel) };
    }

    fn prepareDelete(self: *Tools, a: std.mem.Allocator, args: []const u8, cancel: *gio.Cancellable) anyerror!ActionPreview {
        const parsed = std.json.parseFromSliceLeaky(DeleteArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        const target = try self.resolveDeleteTarget(a, parsed.file_id, cancel);
        defer closeFd(target.fd);
        const absz = try a.dupeSentinel(u8, target.abs, 0);
        defer a.free(absz);
        return .{
            .kind = if (trashSupported(absz)) .delete_file else .delete_file_permanent,
            .target_path = target.abs,
            .content = "",
            .bytes = @intCast(target.st.size),
            .resource = resourceFrom(target.abs, target.st),
        };
    }

    fn executeDelete(self: *Tools, a: std.mem.Allocator, args: []const u8, preview: ActionPreview, cancel: *gio.Cancellable) anyerror![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(DeleteArgs, a, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolCall;
        const target = try self.resolveDeleteTarget(a, parsed.file_id, cancel);
        defer closeFd(target.fd);
        const g = &self.grants[target.gi];
        const current = resourceFrom(target.abs, target.st);
        if (!Resource.sameHandle(current, preview.resource)) return error.StaleApproval;
        if (cancel.isCancelled() != 0) return error.Cancelled;
        const nlink_before = target.st.nlink;
        if (preview.kind == .delete_file_permanent) {
            const absz = try a.dupeSentinel(u8, target.abs, 0);
            defer a.free(absz);
            // A permanent preview is only valid while trash stays unavailable.
            if (trashSupported(absz)) return error.StaleApproval;
            const rc = linux.unlinkat(target.entry.fd, target.entry.name, 0);
            const e = linux.errno(rc);
            if (e != .SUCCESS) return errnoError(e);
            try verifyRemoved(target, nlink_before, nlink_before - 1);
            const rel = try a.dupe(u8, target.entry.rel);
            self.removeHandle(parsed.file_id);
            return std.json.Stringify.valueAlloc(a, .{
                .status = "ok",
                .file_id = parsed.file_id,
                .path = rel,
                .root_path = g.path,
                .target_path = target.abs,
                .kind = "permanent",
                .bytes = @as(usize, @intCast(target.st.size)),
            }, .{});
        }
        // GIO trash anchored at the held parent dirfd. GIO renames the entry
        // itself (lstat + rename), so a swapped-in symlink is trashed as the
        // link and its target is never touched. Identity and link count are
        // re-checked after the call to detect any substitution in the window.
        const proc = try std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ target.entry.fd, target.entry.name }, 0);
        defer a.free(proc);
        const file = gio.File.newForPath(proc);
        defer file.unref();
        var err: ?*glib.Error = null;
        const ok = file.trash(cancel, &err);
        if (ok == 0) {
            if (err) |e| {
                defer e.free();
                if (e.f_domain == gio.ioErrorQuark() and e.f_code == @backingInt(gio.IOErrorEnum.cancelled)) return error.Cancelled;
                if (e.f_domain == gio.ioErrorQuark() and e.f_code == @backingInt(gio.IOErrorEnum.not_supported)) return error.TrashUnavailable;
            }
            if (cancel.isCancelled() != 0) return error.Cancelled;
            return error.TrashFailed;
        }
        if (err) |e| e.free();
        try verifyRemoved(target, nlink_before, nlink_before);
        repairTrashInfo(self, a, target, proc) catch {};
        const rel = try a.dupe(u8, target.entry.rel);
        self.removeHandle(parsed.file_id);
        return std.json.Stringify.valueAlloc(a, .{
            .status = "ok",
            .file_id = parsed.file_id,
            .path = rel,
            .root_path = g.path,
            .target_path = target.abs,
            .kind = "trash",
            .bytes = @as(usize, @intCast(target.st.size)),
        }, .{});
    }

    /// After a removal: the approved entry must be gone, and the held fd must
    /// still describe the approved inode with the expected link count. A
    /// mismatch means a racer substituted the entry; report failure, never ok.
    fn verifyRemoved(target: DeleteTarget, nlink_before: u32, nlink_expected: u32) anyerror!void {
        if (statAt(target.entry.fd, target.entry.name, true)) |_| {
            return error.RaceDetected;
        } else |err| {
            if (err != error.NotFound) return error.RaceDetected;
        }
        const st = statFd(target.fd) catch return error.RaceDetected;
        if (!st.sameFile(target.st) or st.size != target.st.size or st.mtime_sec != target.st.mtime_sec or st.mtime_nsec != target.st.mtime_nsec) return error.RaceDetected;
        if (st.nlink != nlink_expected or nlink_expected > nlink_before) return error.RaceDetected;
    }

    /// g_unix_mount_at only matches mount points themselves, so walk up the
    /// path until a mount entry is found (mirroring GLib's trash internals).
    fn mountForPath(abs_path: []const u8) ?*unix.MountEntry {
        var buf: [4096]u8 = undefined;
        var cur: []const u8 = abs_path;
        while (true) {
            const z = std.mem.printSentinel(&buf, "{s}", .{cur}, 0) catch return null;
            if (unix.mountAt(z, null)) |m| return m;
            if (std.mem.eql(u8, cur, "/")) return null;
            const i = std.mem.lastIndexOfScalar(u8, cur, '/') orelse return null;
            cur = if (i == 0) "/" else cur[0..i];
        }
    }

    fn trashSupported(abs_path: [:0]const u8) bool {
        // GLib trashes files on the home filesystem into the home trash even
        // when the underlying mount is marked system-internal (e.g. "/").
        // Only files on other mounts face the system-internal refusal.
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, abs_path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) == .SUCCESS) {
            const home = std.mem.span(glib.getHomeDir());
            var hbuf: [4096]u8 = undefined;
            if (std.mem.printSentinel(&hbuf, "{s}", .{home}, 0)) |hz| {
                var hstx: linux.Statx = undefined;
                if (linux.errno(linux.statx(linux.AT.FDCWD, hz, 0, .{ .TYPE = true }, &hstx)) == .SUCCESS) {
                    const dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
                    const hdev = (@as(u64, hstx.dev_major) << 32) | hstx.dev_minor;
                    if (dev == hdev) return true;
                }
            } else |_| {}
        }
        const entry = mountForPath(abs_path) orelse return true;
        defer unix.mountFree(entry);
        const opts = std.mem.span(entry.getOptions() orelse "");
        var it = std.mem.splitScalar(u8, opts, ',');
        while (it.next()) |opt| {
            if (std.mem.eql(u8, opt, "x-gvfs-notrash")) return false;
            if (std.mem.eql(u8, opt, "x-gvfs-trash")) return true;
        }
        return unix.mountIsSystemInternal(entry) == 0;
    }

    /// Best-effort: GIO records the /proc anchor as the trash origin. Find the
    /// trashed entry by dev/ino in the candidate trash dirs and rewrite its
    /// .trashinfo Path= to the real display path so restore keeps working.
    fn repairTrashInfo(self: *Tools, a: std.mem.Allocator, target: DeleteTarget, proc: [:0]const u8) anyerror!void {
        _ = self;
        var candidates: std.ArrayList([]const u8) = .empty;
        defer {
            for (candidates.items) |c| a.free(c);
            candidates.deinit(a);
        }
        try candidates.append(a, try std.fmt.allocPrint(a, "{s}/Trash", .{std.mem.span(glib.getUserDataDir())}));
        if (mountForPath(target.abs)) |mount| {
            defer unix.mountFree(mount);
            const mp = std.mem.span(mount.getMountPath());
            try candidates.append(a, try std.fmt.allocPrint(a, "{s}/.Trash/{d}", .{ mp, linux.getuid() }));
            try candidates.append(a, try std.fmt.allocPrint(a, "{s}/.Trash-{d}", .{ mp, linux.getuid() }));
        }
        const how_dir = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_root };
        const how_child = OpenHow{ .flags = O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, .mode = 0, .resolve = resolve_child };
        for (candidates.items) |cand| {
            const cz = try a.dupeSentinel(u8, cand, 0);
            defer a.free(cz);
            const trash_fd = openat2(linux.AT.FDCWD, cz, &how_dir) catch continue;
            defer closeFd(trash_fd);
            const files_fd = openat2(trash_fd, "files", &how_child) catch continue;
            defer closeFd(files_fd);
            const info_fd = openat2(trash_fd, "info", &how_child) catch continue;
            defer closeFd(info_fd);
            var buf: [8192]u8 align(8) = undefined;
            var scanned: usize = 0;
            var found = false;
            while (!found and scanned < 8192) {
                const n = linux.getdents64(files_fd, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    const dent: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
                    off += dent.reclen;
                    scanned += 1;
                    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&dent.name)), 0);
                    // GIO may insert a collision suffix before the extension,
                    // so match by the pinned dev/ino identity, not by name.
                    const st = statAt(files_fd, name, true) catch continue;
                    if (!st.sameFile(target.st)) continue;
                    const info_name = try std.fmt.allocPrintSentinel(a, "{s}.trashinfo", .{name}, 0);
                    defer a.free(info_name);
                    const ifd = openat2(info_fd, info_name, &.{ .flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_child }) catch continue;
                    defer closeFd(ifd);
                    var ibuf: [4096]u8 = undefined;
                    const in_n = readFull(ifd, &ibuf, 0) catch continue;
                    const text = ibuf[0..in_n];
                    const expected = try std.fmt.allocPrint(a, "Path={s}\n", .{proc});
                    defer a.free(expected);
                    if (std.mem.indexOf(u8, text, expected) == null) continue;
                    const replacement = try std.fmt.allocPrint(a, "Path={s}\n", .{target.abs});
                    defer a.free(replacement);
                    const updated = try std.mem.replaceOwned(u8, a, text, expected, replacement);
                    defer a.free(updated);
                    const wfd = openat2(info_fd, info_name, &.{ .flags = O_WRONLY | O_TRUNC | O_NONBLOCK | O_CLOEXEC, .mode = 0, .resolve = resolve_child }) catch continue;
                    defer closeFd(wfd);
                    var done: usize = 0;
                    while (done < updated.len) {
                        const rc = linux.write(wfd, updated[done..].ptr, updated.len - done);
                        const e = linux.errno(rc);
                        if (e == .INTR) continue;
                        if (e != .SUCCESS or rc == 0) break;
                        done += rc;
                    }
                    found = true;
                    break;
                }
            }
            if (found) return;
        }
    }
};

fn joinPath(a: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return a.dupe(u8, base);
    if (base.len == 0) return a.dupe(u8, rel);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel });
}

fn statusFor(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownRoot, error.UnknownHandle, error.NotFound, error.GrantUnavailable, error.HandleStale => "not_found",
        error.LocalFilesDisabled, error.PermissionDenied, error.ProtectedPath, error.ProtectedName, error.SymlinkRejected, error.CrossedMount, error.ApprovalRequired => "denied",
        error.AmbiguousRoot => "ambiguous",
        else => "failed",
    };
}

fn messageFor(err: anyerror) []const u8 {
    return switch (err) {
        error.LocalFilesDisabled => "Local file tools are disabled in Settings. Do not claim file access.",
        error.PermissionDenied => "The folder grant does not allow this operation. Ask the user to adjust folder permissions in Settings.",
        error.ProtectedPath, error.ProtectedName => "This location or file name is protected and cannot be created or deleted by the assistant.",
        error.SymlinkRejected, error.CrossedMount => "The target resolves through a symlink or outside the granted folder, which is not allowed.",
        error.ApprovalRequired => "This action changes files and must be approved by the user through the host approval flow before it can run.",
        error.UnknownRoot, error.UnknownHandle, error.NotFound, error.GrantUnavailable, error.HandleStale => "The referenced folder or file handle is unknown, expired, or no longer resolves. Search again to obtain fresh ids.",
        error.AlreadyExists => "A file with that name already exists. Overwriting is not allowed; choose a different name.",
        error.FileTooLarge => "The file exceeds the size limit for this tool.",
        error.BinaryFile, error.InvalidUtf8 => "The file is not UTF-8 text; only text files can be read.",
        error.NotRegularFile, error.DirectoriesNotSupported, error.IsDirectory, error.NotDirectory => "Only regular files inside granted folders are supported; directories and special files are not.",
        error.TrashUnavailable, error.TrashFailed => "Moving to the trash is unavailable here. No permanent deletion was performed; ask the user how to proceed.",
        error.StaleApproval, error.RaceDetected => "The approved file or folder changed since approval. Nothing was deleted or created; request a fresh approval.",
        error.ResolverUnsupported, error.RenameUnsupported => "This system lacks the required safe filesystem operations; the tool fails closed.",
        error.Cancelled => "The operation was cancelled.",
        else => "The local file tool did not succeed. Explain the limitation when relevant; do not invent results.",
    };
}

fn jsonForError(a: std.mem.Allocator, err: anyerror) anyerror![]const u8 {
    if (err == error.Cancelled or err == error.OutOfMemory) return err;
    return std.json.Stringify.valueAlloc(a, .{
        .status = statusFor(err),
        .@"error" = @errorName(err),
        .message = messageFor(err),
    }, .{});
}

fn denyJson(a: std.mem.Allocator, err: anyerror) anyerror![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .status = "denied",
        .@"error" = @errorName(err),
        .message = messageFor(err),
    }, .{});
}

fn failJson(a: std.mem.Allocator, err: anyerror) anyerror![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .status = "failed",
        .@"error" = @errorName(err),
        .message = messageFor(err),
    }, .{});
}

test "resource identity compares dev, ino, size and mtime, never the display path" {
    const x = Resource{ .path = "/a", .dev = 1, .ino = 2, .size = 3, .mtime_sec = 4, .mtime_nsec = 5 };
    const y = Resource{ .path = "/b", .dev = 1, .ino = 2, .size = 3, .mtime_sec = 4, .mtime_nsec = 5 };
    try std.testing.expect(Resource.sameHandle(x, y));
    try std.testing.expect(!Resource.sameHandle(x, .{ .path = "/a", .dev = 1, .ino = 2, .size = 3, .mtime_sec = 4, .mtime_nsec = 6 }));
    try std.testing.expect(!Resource.sameHandle(x, .{ .path = "/a", .dev = 9, .ino = 2, .size = 3, .mtime_sec = 4, .mtime_nsec = 5 }));
}

test "grant paths must be absolute, normalized and outside protected locations" {
    try validateRootPath("/home/zoey/Documents");
    try std.testing.expectError(error.AbsoluteGrantPathRequired, validateRootPath("Documents"));
    try std.testing.expectError(error.InvalidGrantPath, validateRootPath("/home/zoey/../etc"));
    try std.testing.expectError(error.InvalidGrantPath, validateRootPath("/home//zoey"));
    try std.testing.expectError(error.InvalidGrantPath, validateRootPath("/home/zoey/"));
    try std.testing.expectError(error.InvalidGrantPath, validateRootPath("/home/./zoey"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/etc"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/etc/pearl"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/home/zoey/.ssh"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/home/zoey/.config/autostart"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/home/zoey/.config"));
    try validateRootPath("/dev/shm");
    try validateRootPath("/dev/shm/pearl-work");
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/dev/sda"));
    try std.testing.expectError(error.ProtectedGrantPath, validateRootPath("/dev/shmevil"));
    try std.testing.expectError(error.InvalidGrantId, validateGrant(FolderGrant{ .id = "bad id", .path = "/tmp/x" }));
    try std.testing.expectError(error.InvalidGrantId, validateGrant(FolderGrant{ .id = "", .path = "/tmp/x" }));
    try validateGrant(FolderGrant{ .id = "docs-1", .path = "/tmp/x" });
}

test "create names reject launchers, scripts, executables and config dotfiles" {
    try validNewName("notes.txt");
    try validNewName("report-2026.md");
    try std.testing.expectError(error.InvalidName, validNewName(""));
    try std.testing.expectError(error.InvalidName, validNewName(".."));
    try std.testing.expectError(error.InvalidName, validNewName("a/b"));
    try std.testing.expectError(error.InvalidName, validNewName(".pearl-tmp-abc"));
    try std.testing.expectError(error.ProtectedName, validNewName("launcher.desktop"));
    try std.testing.expectError(error.ProtectedName, validNewName("run.sh"));
    try std.testing.expectError(error.ProtectedName, validNewName("tool.exe"));
    try std.testing.expectError(error.ProtectedName, validNewName("unit.service"));
    try std.testing.expectError(error.ProtectedName, validNewName(".bashrc"));
    try std.testing.expectError(error.ProtectedName, validNewName("authorized_keys"));
    try std.testing.expect(protectedContent("#!/bin/sh\necho hi"));
    try std.testing.expect(protectedContent("\x7fELF"));
    try std.testing.expect(!protectedContent("plain text"));
}
