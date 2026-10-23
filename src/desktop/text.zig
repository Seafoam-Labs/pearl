const presentation = @import("../services/power_presentation.zig");
pub const tr = @import("i18n").tr;
/// Charge label shared by the bar and the control panel. Pending charge is the
/// plugged-in-but-held state that charge-threshold firmware reports on AC, so it
/// must not read as ordinary battery use.
pub fn chargeState(state: u32) [:0]const u8 {
    return switch (presentation.Charge.of(state)) {
        .charging => @import("i18n").dtr("pearl", "Charging"),
        .pending_charge => @import("i18n").dtr("pearl", "Plugged in, not charging"),
        .discharging, .pending_discharge => @import("i18n").dtr("pearl", "On battery"),
        .full => @import("i18n").dtr("pearl", "Fully charged"),
        .empty => @import("i18n").dtr("pearl", "Battery empty"),
        .unknown => @import("i18n").dtr("pearl", "Battery"),
    };
}
