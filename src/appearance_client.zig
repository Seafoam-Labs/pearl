//! Shared read-only appearance boundary for standalone GTK applications.
pub const Subscription = @import("ui/appearance_subscription.zig").Subscription;
pub const Snapshot = @import("settings/appearance.zig").Snapshot;
pub const theme = @import("theme/theme.zig");
pub const style = @import("theme/style.zig");
pub const diagnostics = @import("diagnostics/safe_text.zig");
