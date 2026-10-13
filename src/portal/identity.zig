const git = @import("portal_identity").git_variant;
pub const bus_name = if (git) "org.freedesktop.impl.portal.desktop.pearl_git" else "org.freedesktop.impl.portal.desktop.pearl";
pub const policy_path = if (git) "/etc/pearl-git/portal-policy.conf" else "/etc/pearl/portal-policy.conf";
pub const state_name = if (git) "pearl-portal-git" else "pearl-portal";
