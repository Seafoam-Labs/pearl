//! Only Pearl-owned desktop IDs use Pearl catalogs. Third-party GIO text is untouched.
const std = @import("std");
const i18n = @import("i18n");
pub const Field = enum { name, description };
pub fn text(id: []const u8, field: Field, original: [:0]const u8) ?[:0]const u8 {
    if (std.mem.eql(u8, id, "org.aqueous.Pearl.Settings.desktop")) return switch (field) {
        .name => preserveOverride(original, "Pearl Settings", i18n.context("desktop.settings.name", "Pearl Settings")),
        .description => preserveOverride(original, "Configure the Pearl desktop shell", i18n.context("desktop.settings.description", "Configure the Pearl desktop shell")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Pearl.Git.Settings.desktop")) return switch (field) {
        .name => preserveOverride(original, "Pearl Git Settings", i18n.context("desktop.settings.git.name", "Pearl Git Settings")),
        .description => preserveOverride(original, "Configure the Pearl desktop shell", i18n.context("desktop.settings.description", "Configure the Pearl desktop shell")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Pearl.Git.Agent.desktop")) return switch (field) {
        .name => preserveOverride(original, "Pearl Git Assistant", i18n.context("desktop.agent.git.name", "Pearl Git Assistant")),
        .description => preserveOverride(original, "On-device answers with your configured search engines", i18n.context("desktop.agent.description", "On-device answers with your configured search engines")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Pearl.Agent.desktop")) return switch (field) {
        .name => preserveOverride(original, "Pearl Assistant", i18n.context("desktop.agent.name", "Pearl Assistant")),
        .description => preserveOverride(original, "On-device answers with your configured search engines", i18n.context("desktop.agent.description", "On-device answers with your configured search engines")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Phyto.desktop")) return switch (field) {
        .name => preserveOverride(original, "Phyto", "Phyto"),
        .description => preserveOverride(original, "Browse files with Pearl", i18n.dcontext("phyto", "desktop.description", "Browse files with Pearl")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Dome.desktop")) return switch (field) {
        .name => preserveOverride(original, "Dome", "Dome"),
        .description => preserveOverride(original, "Monitor system resources, processes and services", i18n.dcontext("dome", "desktop.description", "Monitor system resources, processes and services")),
    };
    if (std.mem.eql(u8, id, "org.aqueous.Coral.desktop")) return switch (field) {
        .name => preserveOverride(original, "Coral", "Coral"),
        .description => preserveOverride(original, "Write and edit text with local spelling suggestions", i18n.dcontext("coral", "desktop.description", "Write and edit text with local spelling suggestions")),
    };
    return null;
}
fn preserveOverride(original: [:0]const u8, source: []const u8, translated: [:0]const u8) ?[:0]const u8 {
    return if (std.mem.eql(u8, original, source)) translated else null;
}
