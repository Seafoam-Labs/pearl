//! scx's own contract fixtures for scxcli's clients, embedded for the
//! scheduling profile tests. See README.md for where they come from.
pub const Fixture = struct { name: []const u8, bytes: []const u8 };

/// `scxcli list --json`, built by scx_catalog from catalog/profiles.json,
/// a fixed scan and detection/01-cosmos-running.json.
pub const listing = @embedFile("listing.json");

/// Each holds the `scxcli get --json` output for one detection case under
/// "expected".
pub const detection = [_]Fixture{
    .{ .name = "01-cosmos-running", .bytes = @embedFile("detection/01-cosmos-running.json") },
    .{ .name = "02-selected-but-failed", .bytes = @embedFile("detection/02-selected-but-failed.json") },
    .{ .name = "03-nothing-configured", .bytes = @embedFile("detection/03-nothing-configured.json") },
    .{ .name = "04-stopped-selection-kept", .bytes = @embedFile("detection/04-stopped-selection-kept.json") },
    .{ .name = "05-run-with-options", .bytes = @embedFile("detection/05-run-with-options.json") },
    .{ .name = "06-attached-outside-the-unit", .bytes = @embedFile("detection/06-attached-outside-the-unit.json") },
    .{ .name = "07-override-pending", .bytes = @embedFile("detection/07-override-pending.json") },
    .{ .name = "08-no-sched-ext", .bytes = @embedFile("detection/08-no-sched-ext.json") },
    .{ .name = "09-unit-active-not-yet-attached", .bytes = @embedFile("detection/09-unit-active-not-yet-attached.json") },
    .{ .name = "10-later-file-overrides", .bytes = @embedFile("detection/10-later-file-overrides.json") },
    .{ .name = "11-hidden-started-by-run", .bytes = @embedFile("detection/11-hidden-started-by-run.json") },
    .{ .name = "12-hand-written-name", .bytes = @embedFile("detection/12-hand-written-name.json") },
};

/// Catalog files every scx tool accepts, as `scxcli catalog show` prints
/// them.
pub const shipped_catalog = @embedFile("catalog/shipped.json");
pub const version_1_catalog = @embedFile("catalog/version-1.json");
pub const valid_catalogs = [_][]const u8{
    shipped_catalog,
    @embedFile("catalog/profiles.json"),
    @embedFile("catalog/minimal.json"),
    @embedFile("catalog/hidden-and-unicode.json"),
    version_1_catalog,
};
