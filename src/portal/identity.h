#ifndef PEARL_PORTAL_IDENTITY_H
#define PEARL_PORTAL_IDENTITY_H
#ifdef PEARL_PORTAL_GIT
#define PEARL_PORTAL_BUS_NAME "org.freedesktop.impl.portal.desktop.pearl_git"
#define PEARL_PORTAL_POLICY "/etc/pearl-git/portal-policy.conf"
#define PEARL_PORTAL_STATE "pearl-portal-git"
#else
#define PEARL_PORTAL_BUS_NAME "org.freedesktop.impl.portal.desktop.pearl"
#define PEARL_PORTAL_POLICY "/etc/pearl/portal-policy.conf"
#define PEARL_PORTAL_STATE "pearl-portal"
#endif
#endif
