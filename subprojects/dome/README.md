# Dome

Planned native Linux system monitor written in **Zig and GTK4**, with
Mission Center as its functional reference and Pearl's visual language.

**Status: design and implementation plan only.** No application or build targets
have been implemented yet.

Read the [design and implementation plan](docs/IMPLEMENTATION_PLAN.md) for the
interface, feature scope, collection architecture, delivery milestones and
acceptance criteria.

The proposed stack follows sibling project Phyto: Zig 0.16.0, GTK4, GLib/GIO
and Pearl's pinned generated GObject bindings. Dome will launch independently
of Pearl and Aqueous.
