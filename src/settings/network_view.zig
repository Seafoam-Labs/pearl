//! Settings uses the shared retained network UI with its authenticated editor
//! transport. The compact frontend supplies its own service-owned dispatcher.
pub const View = @import("../ui/components/network.zig").View;
pub const Request = @import("../ui/components/network.zig").Request;
