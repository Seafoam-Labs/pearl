test {
    _ = @import("config/preferences.zig");
    _ = @import("services/notification_policy.zig");
    _ = @import("services/connectivity_policy.zig");
    _ = @import("desktop/policy.zig");
    _ = @import("ui/surfaces/policy.zig");
    _ = @import("cli/options.zig");
    _ = @import("cli/protocol.zig");
    _ = @import("core/tests.zig");
    _ = @import("aqueous/tests.zig");
    _ = @import("theme/theme.zig");
    _ = @import("ui/i18n.zig");
}

comptime {
    _ = @import("services/policy.zig");
}
