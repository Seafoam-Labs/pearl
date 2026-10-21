const std = @import("std");
const glib = @import("glib2");
const i18n = @import("../ui/i18n.zig");
const presentation = @import("../services/power_presentation.zig");
pub fn tr(en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
    const locale = glib.getLanguageNames()[0];
    return if (i18n.fromLocale(std.mem.span(locale)) == .de) de else en;
}
/// Charge label shared by the bar and the control panel. Pending charge is the
/// plugged-in-but-held state that charge-threshold firmware reports on AC, so it
/// must not read as ordinary battery use.
pub fn chargeState(state: u32) [:0]const u8 {
    return switch (presentation.Charge.of(state)) {
        .charging => tr("Charging", "Wird geladen"),
        .pending_charge => tr("Plugged in, not charging", "Angeschlossen, lädt nicht"),
        .discharging, .pending_discharge => tr("On battery", "Akkubetrieb"),
        .full => tr("Fully charged", "Vollständig geladen"),
        .empty => tr("Battery empty", "Akku leer"),
        .unknown => tr("Battery", "Akku"),
    };
}
