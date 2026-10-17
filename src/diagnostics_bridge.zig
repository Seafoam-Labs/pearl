//! Re-exports Pearl's redaction helpers through the shared appearance boundary
//! so the safe_text source belongs to a single module.
const shared = @import("appearance_client").diagnostics;
pub const limit = shared.limit;
pub const SafeText = shared.SafeText;
pub const safe = shared.safe;
pub const Fingerprint = shared.Fingerprint;
pub const fingerprint = shared.fingerprint;
