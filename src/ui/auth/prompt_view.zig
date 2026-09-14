//! Backend-free authentication presentation shared by locker and greeter.
const gtk = @import("gtk4");
const glib = @import("glib2");
pub const css = ".pearl-lock-clock { font-size: 6em; font-weight: 300; letter-spacing: -0.04em; } .pearl-lock-date { font-size: 1.3em; } .pearl-lock-card { padding: 28px; border-radius: 28px; } .pearl-lock-small .pearl-lock-clock { font-size: 3em; } .pearl-lock-small .pearl-lock-card { padding: 16px; } .pearl-lock entry { min-height: 40px; } .pearl-lock button { min-height: 40px; }";
pub fn secureEntry(max_characters: c_int) *gtk.Entry {
    const entry = gtk.Entry.new();
    const buffer = gtk.PasswordEntryBuffer.new();
    entry.setBuffer(buffer.as(gtk.EntryBuffer));
    buffer.unref();
    entry.setVisibility(0);
    // One character beyond the byte limit permits rejection, never prefix auth.
    entry.setMaxLength(max_characters);
    entry.as(gtk.Editable).setWidthChars(10);
    entry.as(gtk.Editable).setMaxWidthChars(24);
    entry.setInputPurpose(.password);
    entry.setPlaceholderText("Password");
    entry.setInputHints(.{ .private = true, .no_spellcheck = true, .no_emoji = true });
    return entry;
}
pub fn updateClock(clock: *gtk.Label, date: *gtk.Label) void {
    const now = glib.DateTime.newNowLocal() orelse return;
    defer now.unref();
    const time = now.format("%H:%M") orelse return;
    defer glib.free(time);
    const day = now.format("%A, %B %e") orelse return;
    defer glib.free(day);
    clock.setText(time);
    date.setText(day);
}
