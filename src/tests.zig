test {
    _ = @import("settings/bar_model.zig");
    _ = @import("theme/package_model.zig");
    _ = @import("theme/style.zig");
    _ = @import("plugins/model.zig");
    _ = @import("plugins/placement.zig");
    _ = @import("plugins/discovery_policy.zig");
    _ = @import("settings/live_protocol.zig");
    _ = @import("plugins/protocol.zig");
    _ = @import("config/ini.zig");
    _ = @import("config/json_keys.zig");
    _ = @import("theme/qt.zig");
    _ = @import("settings/distribution.zig");
    _ = @import("settings/editor_protocol.zig");
    _ = @import("settings/transfer.zig");
    _ = @import("config/draft.zig");
    _ = @import("settings/appearance.zig");
    _ = @import("settings/activation.zig");
    _ = @import("settings/options.zig");
    _ = @import("settings/protocol.zig");
    _ = @import("config/dms_import.zig");
    _ = @import("desktop/dock_policy.zig");
    _ = @import("services/clipboard_policy.zig");
    _ = @import("lock/conversation.zig");
    _ = @import("services/idle_policy.zig");
    _ = @import("services/session_environment.zig");
    _ = @import("config/aqueous_model.zig");
    _ = @import("config/aqueous_draft.zig");
    _ = @import("config/border_theme.zig");
    _ = @import("config/aqueous_contract.zig");
    _ = @import("config/aqueous_collections.zig");
    _ = @import("config/aqueous_transactions.zig");
    _ = @import("config/aqueous_display_mutations.zig");
    _ = @import("config/aqueous_display_setup.zig");
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

test {
    _ = @import("plugins/activity_policy.zig");
}
