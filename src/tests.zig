test {
    _ = @import("config/dms_import.zig");
    _ = @import("desktop/dock_policy.zig");
    _ = @import("services/clipboard_policy.zig");
    _ = @import("lock/conversation.zig");
    _ = @import("services/idle_policy.zig");
    _ = @import("config/aqueous_model.zig");
    _ = @import("config/aqueous_contract.zig");
    _ = @import("config/aqueous_collections.zig");
    _ = @import("config/aqueous_transactions.zig");
    _ = @import("config/aqueous_display_mutations.zig");
    _ = @import("config/preferences.zig");
    _ = @import("config/merge.zig");
    _ = @import("services/notification_policy.zig");
    _ = @import("services/connectivity_policy.zig");
    _ = @import("desktop/policy.zig");
    _ = @import("desktop/settings_navigation.zig");
    _ = @import("services/view_ownership.zig");
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
