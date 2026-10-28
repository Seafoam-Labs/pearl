//! Appearance and Advanced presentation for the normal application host.
//! Form extraction preserves every other Pearl preference; only Editor retains
//! drafts. Wallpaper preview/chooser never changes committed appearance.
const files = @import("file_chooser");
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const model = @import("../config/preferences.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const Section = struct {
    expander: *gtk.Expander,
    body: *gtk.Box,
    summary: *gtk.Label,
    fn create(host: *gtk.Box, title: [:0]const u8, description: [:0]const u8) Section {
        const expander = gtk.Expander.new(null);
        expander.as(gtk.Widget).addCssClass("settings-card");
        expander.as(gtk.Widget).addCssClass("appearance-section");
        expander.as(gtk.Widget).addCssClass("settings-section");
        w.tagExpanderArrow(expander, "settings-section-arrow");
        const heading = w.column(5);
        heading.as(gtk.Widget).addCssClass("settings-section-heading");
        heading.append(w.label(title, "pearl-section-title").as(gtk.Widget));
        const summary = w.label(description, "pearl-secondary");
        heading.append(summary.as(gtk.Widget));
        expander.setLabelWidget(heading.as(gtk.Widget));
        w.name(expander.as(gtk.Widget), title);
        const body = w.column(8);
        // A collapsed expander drops its body from the child list, so body
        // rules must key on a class, never on child position.
        body.as(gtk.Widget).addCssClass("appearance-section-body");
        expander.setChild(body.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        return .{ .expander = expander, .body = body, .summary = summary };
    }
};
pub const ModeChoice = struct {
    buttons: [4]*gtk.CheckButton,
    fn create(host: *gtk.Box) ModeChoice {
        const flow = w.flow(4);
        flow.setHomogeneous(1);
        flow.as(gtk.Widget).addCssClass("appearance-modes");
        var result: ModeChoice = undefined;
        const titles: [4][:0]const u8 = .{ @import("i18n").dtr("pearl", "Material"), @import("i18n").dtr("pearl", "Dynamic"), @import("i18n").dtr("pearl", "GTK"), @import("i18n").dtr("pearl", "Community") };
        const descriptions: [4][:0]const u8 = .{ @import("i18n").dtr("pearl", "Built-in colors"), @import("i18n").dtr("pearl", "Wallpaper or seed"), @import("i18n").dtr("pearl", "System theme"), @import("i18n").dtr("pearl", "Installed themes") };
        for (titles, descriptions, 0..) |title, description, i| {
            const button = gtk.CheckButton.new();
            if (i > 0) button.setGroup(result.buttons[0]);
            button.as(gtk.Widget).addCssClass("appearance-mode");
            const content = w.column(6);
            content.append(w.label(title, "settings-row-title").as(gtk.Widget));
            const subtitle = w.label(description, "pearl-secondary");
            subtitle.setMaxWidthChars(13);
            content.append(subtitle.as(gtk.Widget));
            button.setChild(content.as(gtk.Widget));
            w.name(button.as(gtk.Widget), title);
            flow.insert(button.as(gtk.Widget), -1);
            result.buttons[i] = button;
        }
        result.buttons[0].setActive(1);
        host.append(flow.as(gtk.Widget));
        return result;
    }
    pub fn getSelected(self: ModeChoice) c_uint {
        for (self.buttons, 0..) |button, i| if (button.getActive() != 0) return @intCast(i);
        return 0;
    }
    fn setSelected(self: ModeChoice, index: c_uint) void {
        self.buttons[@min(index, 3)].setActive(1);
    }
    pub fn widget(self: ModeChoice) *gtk.Widget {
        return self.buttons[self.getSelected()].as(gtk.Widget);
    }
};
pub const View = struct {
    editor: *Editor,
    window: *gtk.Window,
    host: *gtk.Box,
    raw_view: *gtk.TextView,
    raw: *gtk.TextBuffer,
    raw_insert_signal: c_ulong = 0,
    raw_changed_signal: c_ulong = 0,
    arena: std.heap.ArenaAllocator,
    prefs: model.Preferences = .{},
    shown: ?[:0]u8 = null,
    filling: bool = false,
    editing_form: bool = false,
    raw_invalid: bool = false,
    mode: ModeChoice,
    desktop_preview: *@import("appearance_preview.zig").View,
    wallpaper_summary: *gtk.Label,
    wallpaper_thumbnail: *gtk.Picture,
    customize: *gtk.Button,
    image_section: Section,
    text_section: Section,
    desktop_section: Section = undefined,
    night_section: Section = undefined,
    apps_section: Section,
    themes_section: Section = undefined,
    login_section: Section = undefined,
    sync_borders: *gtk.Switch = undefined,
    variant: *gtk.DropDown,
    source: *gtk.DropDown,
    scheme: *gtk.DropDown,
    fit: *gtk.DropDown,
    density: *gtk.DropDown,
    entries: [5]*gtk.Entry,
    font_size: *gtk.SpinButton,
    language: *gtk.DropDown = undefined,
    language_arena: std.heap.ArenaAllocator = .init(a),
    language_codes: std.ArrayList([:0]const u8) = .empty,
    motion: *gtk.Switch,
    picture: *gtk.Picture,
    preview_note: *gtk.Label,
    preview_css: *gtk.CssProvider,
    preview_key: ?[]u8 = null,
    preview_idle: c_uint = 0,
    palette_key: ?[]u8 = null,
    palette_idle: c_uint = 0,
    preview: ?*Preview = null,
    preview_ready: bool = false,
    choose: *gtk.Button,
    picker: ?*gtk.Dialog = null,
    slideshow_enabled: *gtk.Switch = undefined,
    slideshow_folder: *gtk.Entry = undefined,
    slideshow_choose: *gtk.Button = undefined,
    slideshow_interval: *gtk.SpinButton = undefined,
    slideshow_order: *gtk.DropDown = undefined,
    slideshow_transition: *gtk.DropDown = undefined,
    slideshow_duration: *gtk.SpinButton = undefined,
    folder_picker: ?*gtk.Dialog = null,
    message: *gtk.Label,
    mode_hint: *gtk.Label,
    qt_enabled: *gtk.Switch,
    qt5: *gtk.Switch,
    qt6: *gtk.Switch,
    qt_palette: *gtk.DropDown,
    qt_font: *gtk.Switch,
    qt_icon: *gtk.Entry,
    qt_radius: *gtk.SpinButton,
    qt_motion: *gtk.Switch,
    qt_density: *gtk.Switch,
    qt_kde: *gtk.Switch,
    qt_status: *gtk.Label,
    qt_retry: *gtk.Button,
    qt_review: *gtk.Button,
    qt_reapply: *gtk.Button,
    qt_comparison: *gtk.Label,
    night_enabled: *gtk.Switch = undefined,
    desktop_enabled: *gtk.Switch = undefined,
    desktop_hidden: *gtk.Switch = undefined,
    desktop_output: *gtk.Entry = undefined,
    desktop_size: *gtk.DropDown = undefined,
    desktop_arrangement: *gtk.DropDown = undefined,
    night_temperature: *gtk.SpinButton = undefined,
    night_schedule: *gtk.DropDown = undefined,
    night_times: [4]*gtk.SpinButton = undefined,
    night_status: *gtk.Label = undefined,
    night_resume: *gtk.Button = undefined,
    themes: *@import("themes_view.zig").View = undefined,
    profiles: *@import("profiles_view.zig").View = undefined,
    greeter_sync: *@import("greeter_sync.zig").View = undefined,

    pub fn create(window: *gtk.Window, host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        host.as(gtk.Widget).addCssClass("appearance-view");
        host.setSpacing(16);
        const preview_card = card(host);
        const desktop_preview = try @import("appearance_preview.zig").View.create(preview_card);
        const preview_note = w.label("", "pearl-secondary");
        const appearance = card(host);
        appearance.append(w.label(@import("i18n").dtr("pearl", "Theme & colors"), "pearl-section-title").as(gtk.Widget));
        const mode = ModeChoice.create(appearance);
        const variant = dropdown(appearance, @import("i18n").dtr("pearl", "Color variant"), &.{ "Dark", "Light" });
        const source = dropdown(appearance, @import("i18n").dtr("pearl", "Dynamic colors from"), &.{ "Seed color", "Wallpaper" });
        const scheme = dropdown(appearance, @import("i18n").dtr("pearl", "Matugen scheme"), &.{ "Content", "Expressive", "Fidelity", "Fruit salad", "Monochrome", "Neutral", "Rainbow", "Tonal spot", "Vibrant", "Smart" });
        const gtk_name = entry(appearance, @import("i18n").dtr("pearl", "GTK theme name"), 96);
        gtk_name.setPlaceholderText(@import("i18n").dtr("pearl", "System default"));
        const seed = entry(appearance, @import("i18n").dtr("pearl", "Seed color"), 7);
        seed.setPlaceholderText(@import("i18n").dtr("pearl", "#6750a4"));
        const hint = w.label(@import("i18n").dtr("pearl", "Dynamic colors need matugen 4.x. An empty GTK theme name follows the system."), "pearl-secondary");
        appearance.append(hint.as(gtk.Widget));
        const customize = w.wrappingButton(@import("i18n").dtr("pearl", "Installed themes & customization…"));
        customize.as(gtk.Widget).addCssClass("appearance-action");
        appearance.append(customize.as(gtk.Widget));
        const wallpaper = card(host);
        wallpaper.append(w.label(@import("i18n").dtr("pearl", "Wallpaper"), "pearl-section-title").as(gtk.Widget));
        const picture = desktop_preview.picture;
        w.name(picture.as(gtk.Widget), @import("i18n").dtr("pearl", "Wallpaper draft preview"));
        const wallpaper_row = w.flow(3);
        wallpaper_row.setHomogeneous(0);
        wallpaper_row.as(gtk.Widget).addCssClass("appearance-wallpaper-row");
        const thumbnail = gtk.Picture.new();
        thumbnail.setCanShrink(1);
        thumbnail.setContentFit(.cover);
        thumbnail.as(gtk.Widget).setSizeRequest(96, 60);
        thumbnail.as(gtk.Widget).setHalign(.start);
        thumbnail.as(gtk.Widget).addCssClass("settings-draft-preview");
        wallpaper_row.insert(thumbnail.as(gtk.Widget), -1);
        const wallpaper_summary = w.label("", "settings-row-title");
        wallpaper_summary.setMaxWidthChars(28);
        wallpaper_summary.setSelectable(1);
        wallpaper_row.insert(wallpaper_summary.as(gtk.Widget), -1);
        const choose = w.wrappingButton(@import("i18n").dtr("pearl", "Choose image…"));
        wallpaper_row.insert(choose.as(gtk.Widget), -1);
        wallpaper.append(wallpaper_row.as(gtk.Widget));
        wallpaper.append(preview_note.as(gtk.Widget));
        const image_section = Section.create(wallpaper, @import("i18n").dtr("pearl", "Image options & slideshow"), @import("i18n").dtr("pearl", "Path, fit and rotating images"));
        const path = entry(image_section.body, @import("i18n").dtr("pearl", "Wallpaper image"), 1024);
        path.setPlaceholderText(@import("i18n").dtr("pearl", "No image selected"));
        const fit = dropdown(image_section.body, @import("i18n").dtr("pearl", "Wallpaper fit"), &.{ @import("i18n").dtr("pearl", "Material gradient"), @import("i18n").dtr("pearl", "Solid color"), @import("i18n").dtr("pearl", "Cover"), @import("i18n").dtr("pearl", "Contain") });
        const color = entry(image_section.body, @import("i18n").dtr("pearl", "Background color"), 7);
        // One card owns the whole wallpaper area; the slideshow is a section of it.
        // Built from locals because `self` is only assigned after every card exists.
        const slideshow = image_section.body;
        const divider = gtk.Separator.new(.horizontal);
        divider.as(gtk.Widget).setMarginTop(16);
        divider.as(gtk.Widget).setMarginBottom(16);
        slideshow.append(divider.as(gtk.Widget));
        slideshow.append(w.label(@import("i18n").dtr("pearl", "Slideshow"), "settings-row-title").as(gtk.Widget));
        slideshow.append(w.label(@import("i18n").dtr("pearl", "Rotates through the images in one folder. Only PNG and JPEG are used. Each change re-runs wallpaper colors when the theme follows the image."), "pearl-secondary").as(gtk.Widget));
        const slideshow_enabled = toggle(slideshow, @import("i18n").dtr("pearl", "Enable slideshow"));
        const slideshow_folder = entry(slideshow, @import("i18n").dtr("pearl", "Image folder"), 1024);
        slideshow_folder.setPlaceholderText(@import("i18n").dtr("pearl", "No folder selected"));
        const slideshow_choose = w.wrappingButton(@import("i18n").dtr("pearl", "Choose folder…"));
        slideshow_choose.as(gtk.Widget).setHalign(.end);
        slideshow_choose.as(gtk.Widget).setMarginEnd(20);
        slideshow_choose.as(gtk.Widget).setMarginBottom(12);
        slideshow.append(slideshow_choose.as(gtk.Widget));
        const slideshow_interval = gtk.SpinButton.newWithRange(10, 86400, 10);
        row(slideshow, @import("i18n").dtr("pearl", "Change every (seconds)"), slideshow_interval.as(gtk.Widget));
        const slideshow_order = dropdown(slideshow, @import("i18n").dtr("pearl", "Order"), &.{ @import("i18n").dtr("pearl", "Sequential"), @import("i18n").dtr("pearl", "Random") });
        const slideshow_transition = dropdown(slideshow, @import("i18n").dtr("pearl", "Transition"), &.{ @import("i18n").dtr("pearl", "None"), @import("i18n").dtr("pearl", "Fade"), @import("i18n").dtr("pearl", "Slide"), @import("i18n").dtr("pearl", "Rotate"), @import("i18n").dtr("pearl", "Cover"), @import("i18n").dtr("pearl", "Random") });
        const slideshow_duration = gtk.SpinButton.newWithRange(100, 5000, 20);
        row(slideshow, @import("i18n").dtr("pearl", "Animation length (ms)"), slideshow_duration.as(gtk.Widget));
        const text_section = Section.create(host, @import("i18n").dtr("pearl", "Text & layout"), "");
        const language = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ @import("i18n").tr("Follow system").ptr, @import("i18n").dtr("pearl", "English"), null }));
        row(text_section.body, @import("i18n").tr("Interface language"), language.as(gtk.Widget));
        text_section.body.append(w.label(@import("i18n").tr("Install language packs with your package manager. Changes take full effect after signing out and back in."), "pearl-secondary").as(gtk.Widget));
        const typography = text_section.body;
        const font = entry(typography, @import("i18n").dtr("pearl", "Font family"), 96);
        font.setPlaceholderText(@import("i18n").dtr("pearl", "System default"));
        const font_size = gtk.SpinButton.newWithRange(10, 24, 1);
        row(typography, @import("i18n").dtr("pearl", "Font size"), font_size.as(gtk.Widget));
        const density = dropdown(typography, @import("i18n").dtr("pearl", "Density"), &.{ "Comfortable", "Compact" });
        const motion = gtk.Switch.new();
        row(typography, @import("i18n").dtr("pearl", "Reduced motion"), motion.as(gtk.Widget));
        const apps_section = Section.create(host, @import("i18n").dtr("pearl", "Application appearance"), @import("i18n").dtr("pearl", "Window borders, Qt and application colors"));
        const sync_borders = toggle(apps_section.body, @import("i18n").dtr("pearl", "Window borders follow Pearl theme"));
        apps_section.body.append(w.label(@import("i18n").dtr("pearl", "Waits for pending Aqueous edits. Turning off keeps the last colors; GTK mode pauses synchronization."), "pearl-secondary").as(gtk.Widget));
        const qt_card = card(apps_section.body);
        qt_card.append(w.label(@import("i18n").dtr("pearl", "Qt applications · QtEngine + Darkly"), "settings-row-title").as(gtk.Widget));
        qt_card.append(w.label(@import("i18n").dtr("pearl", "QtEngine shares one configuration across Qt 5 and Qt 6. Selected checks verify the installed runtimes. Changes affect this user account. GTK mode uses Pearl's static colors. Disabling restores previous values that have not been edited elsewhere."), "pearl-secondary").as(gtk.Widget));
        const qt_enabled = toggle(qt_card, @import("i18n").dtr("pearl", "Manage Qt appearance"));
        const qt5 = toggle(qt_card, @import("i18n").dtr("pearl", "Check Qt 5"));
        const qt6 = toggle(qt_card, @import("i18n").dtr("pearl", "Check Qt 6"));
        const qt_palette = dropdown(qt_card, @import("i18n").dtr("pearl", "Qt colors"), &.{ @import("i18n").dtr("pearl", "Follow Pearl"), @import("i18n").dtr("pearl", "Static dark"), @import("i18n").dtr("pearl", "Static light") });
        const qt_font = toggle(qt_card, @import("i18n").dtr("pearl", "Synchronize font"));
        const qt_icon = entry(qt_card, @import("i18n").dtr("pearl", "Qt icon theme"), 96);
        qt_icon.setPlaceholderText(@import("i18n").dtr("pearl", "Keep existing setting"));
        const qt_radius = gtk.SpinButton.newWithRange(0, 16, 1);
        row(qt_card, @import("i18n").dtr("pearl", "Corner radius (0: keep existing)"), qt_radius.as(gtk.Widget));
        const qt_motion = toggle(qt_card, @import("i18n").dtr("pearl", "Synchronize reduced motion"));
        const qt_density = toggle(qt_card, @import("i18n").dtr("pearl", "Synchronize density"));
        const qt_kde = toggle(qt_card, @import("i18n").dtr("pearl", "Synchronize Darkly focus colors in KDE"));
        const qt_status = w.label("", "pearl-secondary");
        qt_status.setSelectable(1);
        qt_card.append(qt_status.as(gtk.Widget));
        const qt_retry = w.wrappingButton(@import("i18n").dtr("pearl", "Retry saved Qt settings"));
        qt_card.append(qt_retry.as(gtk.Widget));
        const qt_review = w.wrappingButton(@import("i18n").dtr("pearl", "Review external Qt changes"));
        qt_card.append(qt_review.as(gtk.Widget));
        const qt_comparison = w.label("", "pearl-secondary");
        qt_comparison.setSelectable(1);
        qt_card.append(qt_comparison.as(gtk.Widget));
        const qt_reapply = w.wrappingButton(@import("i18n").dtr("pearl", "Replace reviewed values with saved Qt settings"));
        qt_card.append(qt_reapply.as(gtk.Widget));
        const message = w.label("", "pearl-secondary");
        host.append(message.as(gtk.Widget));
        const raw_view = gtk.TextView.new();
        raw_view.setMonospace(1);
        raw_view.setWrapMode(.word_char);
        raw_view.setTopMargin(12);
        raw_view.setBottomMargin(20);
        raw_view.setLeftMargin(24);
        raw_view.setRightMargin(24);
        w.name(raw_view.as(gtk.Widget), @import("i18n").dtr("pearl", "Full Pearl preferences JSON"));
        // The caller installs raw_view directly in Advanced's sole viewport.
        self.* = .{ .editor = editor, .window = window, .host = host, .raw_view = raw_view, .raw = raw_view.getBuffer(), .arena = .init(a), .mode = mode, .desktop_preview = desktop_preview, .wallpaper_summary = wallpaper_summary, .wallpaper_thumbnail = thumbnail, .customize = customize, .image_section = image_section, .text_section = text_section, .apps_section = apps_section, .variant = variant, .source = source, .scheme = scheme, .fit = fit, .density = density, .entries = .{ gtk_name, seed, path, color, font }, .font_size = font_size, .motion = motion, .picture = picture, .preview_note = preview_note, .preview_css = gtk.CssProvider.new(), .choose = choose, .message = message, .mode_hint = hint, .qt_enabled = qt_enabled, .qt5 = qt5, .qt6 = qt6, .qt_palette = qt_palette, .qt_font = qt_font, .qt_icon = qt_icon, .qt_radius = qt_radius, .qt_motion = qt_motion, .qt_density = qt_density, .qt_kde = qt_kde, .qt_status = qt_status, .qt_retry = qt_retry, .qt_review = qt_review, .qt_reapply = qt_reapply, .qt_comparison = qt_comparison, .slideshow_enabled = slideshow_enabled, .slideshow_folder = slideshow_folder, .slideshow_choose = slideshow_choose, .slideshow_interval = slideshow_interval, .slideshow_order = slideshow_order, .slideshow_transition = slideshow_transition, .slideshow_duration = slideshow_duration };
        self.language = language;
        const language_alloc = self.language_arena.allocator();
        try self.language_codes.appendSlice(language_alloc, &.{ "", "en" });
        const language_strings = object.ext.cast(gtk.StringList, language.getModel().?).?;
        for (try @import("i18n").installed(language_alloc)) |pack| {
            if (std.mem.eql(u8, pack.locale, "en")) continue;
            try self.language_codes.append(language_alloc, pack.locale);
            const label = if (pack.total == 0 or pack.translated == pack.total) pack.name else try std.fmt.allocPrintSentinel(language_alloc, "{s} · {d}%", .{ pack.name, @as(u64, pack.translated) * 100 / pack.total }, 0);
            language_strings.append(label);
        }
        _ = object.Object.signals.notify.connect(language.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        self.desktop_section = Section.create(host, @import("i18n").dtr("pearl", "Desktop icons"), "");
        const desktop = self.desktop_section.body;
        desktop.append(w.label(@import("i18n").dtr("pearl", "Files and application shortcuts from your Desktop folder. Enabled automatically for new installations."), "pearl-secondary").as(gtk.Widget));
        self.desktop_enabled = toggle(desktop, @import("i18n").dtr("pearl", "Show desktop icons"));
        self.desktop_output = entry(desktop, @import("i18n").dtr("pearl", "Display connector"), 128);
        self.desktop_output.setPlaceholderText(@import("i18n").dtr("pearl", "Automatic (first connected display)"));
        self.desktop_size = dropdown(desktop, @import("i18n").dtr("pearl", "Icon size"), &.{ "32", "48", "64", "96" });
        self.desktop_arrangement = dropdown(desktop, @import("i18n").dtr("pearl", "Arrangement"), &.{ @import("i18n").dtr("pearl", "Automatic · Name"), @import("i18n").dtr("pearl", "Manual") });
        self.desktop_hidden = toggle(desktop, @import("i18n").dtr("pearl", "Show hidden files"));
        for ([_]*gtk.Switch{ self.desktop_enabled, self.desktop_hidden }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "active" });
        for ([_]*gtk.DropDown{ self.desktop_size, self.desktop_arrangement }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.Editable.signals.changed.connect(self.desktop_output.as(gtk.Editable), *View, edited, self, .{});
        self.night_section = Section.create(host, @import("i18n").dtr("pearl", "Night Light"), "");
        const night = self.night_section.body;
        night.append(w.label(@import("i18n").dtr("pearl", "Warmer screen colors on supported displays. The status below shows which displays can apply your saved schedule."), "pearl-secondary").as(gtk.Widget));
        self.night_enabled = toggle(night, @import("i18n").dtr("pearl", "Enable Night Light"));
        self.night_temperature = gtk.SpinButton.newWithRange(2500, 6500, 100);
        row(night, @import("i18n").dtr("pearl", "Color temperature (K) · lower is warmer"), self.night_temperature.as(gtk.Widget));
        self.night_schedule = dropdown(night, @import("i18n").dtr("pearl", "Schedule"), &.{ @import("i18n").dtr("pearl", "Manual"), @import("i18n").dtr("pearl", "Custom times") });
        for (0..2) |i| {
            const time_row = w.row(4);
            const hour = gtk.SpinButton.newWithRange(0, 23, 1);
            const minute = gtk.SpinButton.newWithRange(0, 59, 1);
            w.name(hour.as(gtk.Widget), if (i == 0) @import("i18n").dtr("pearl", "Start hour") else @import("i18n").dtr("pearl", "End hour"));
            w.name(minute.as(gtk.Widget), if (i == 0) @import("i18n").dtr("pearl", "Start minute") else @import("i18n").dtr("pearl", "End minute"));
            time_row.append(hour.as(gtk.Widget));
            time_row.append(w.label(@import("i18n").dtr("pearl", ":"), null).as(gtk.Widget));
            time_row.append(minute.as(gtk.Widget));
            row(night, if (i == 0) @import("i18n").dtr("pearl", "Start (local time)") else @import("i18n").dtr("pearl", "End (local time)"), time_row.as(gtk.Widget));
            self.night_times[i * 2] = hour;
            self.night_times[i * 2 + 1] = minute;
        }
        self.night_status = w.label("", "pearl-secondary");
        night.append(self.night_status.as(gtk.Widget));
        self.night_resume = w.wrappingButton(@import("i18n").dtr("pearl", "Resume saved policy"));
        night.append(self.night_resume.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.night_resume, *View, resumeNight, self, .{});
        _ = object.Object.signals.notify.connect(self.night_enabled.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(self.night_schedule.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(self.night_temperature, *View, spun, self, .{});
        for (self.night_times) |control| _ = gtk.SpinButton.signals.value_changed.connect(control, *View, spun, self, .{});
        host.reorderChildAfter(apps_section.expander.as(gtk.Widget), self.night_section.expander.as(gtk.Widget));
        self.themes_section = Section.create(host, @import("i18n").dtr("pearl", "Themes & customization"), @import("i18n").dtr("pearl", "Installed themes, palettes and widget styles"));
        self.themes = try @import("themes_view.zig").View.create(self.themes_section.body, editor);
        self.themes.preview_context = self;
        self.themes.preview_callback = previewPalette;
        self.profiles = try @import("profiles_view.zig").View.create(apps_section.body, editor);
        self.login_section = Section.create(host, @import("i18n").dtr("pearl", "Login screen"), @import("i18n").dtr("pearl", "Copy appearance with administrator authentication"));
        self.greeter_sync = try @import("greeter_sync.zig").View.create(self.login_section.body, self, syncPreferences);
        host.reorderChildAfter(message.as(gtk.Widget), null);
        self.sync_borders = sync_borders;
        _ = object.Object.signals.notify.connect(sync_borders.as(object.Object), *View, selected, self, .{ .detail = "active" });
        gtk.StyleContext.addProviderForDisplay(window.as(gtk.Widget).getDisplay(), self.preview_css.as(gtk.StyleProvider), 602);
        _ = gtk.Button.signals.clicked.connect(qt_retry, *View, retryQt, self, .{});
        _ = gtk.Button.signals.clicked.connect(qt_review, *View, reviewQt, self, .{});
        _ = gtk.Button.signals.clicked.connect(qt_reapply, *View, reapplyQt, self, .{});
        for ([_]*gtk.Switch{ qt_enabled, qt5, qt6, qt_font, qt_motion, qt_density, qt_kde }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(qt_palette.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.Editable.signals.changed.connect(qt_icon.as(gtk.Editable), *View, edited, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(qt_radius, *View, spun, self, .{});
        for (self.entries) |control| _ = gtk.Editable.signals.changed.connect(control.as(gtk.Editable), *View, edited, self, .{});
        for (mode.buttons) |control| _ = gtk.CheckButton.signals.toggled.connect(control, *View, modeChosen, self, .{});
        _ = gtk.Button.signals.clicked.connect(customize, *View, openThemes, self, .{});
        for ([_]*gtk.DropDown{ variant, source, scheme, fit, density }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(font_size, *View, spun, self, .{});
        _ = object.Object.signals.notify.connect(motion.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(choose, *View, chooseWallpaper, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.slideshow_choose, *View, chooseFolder, self, .{});
        _ = object.Object.signals.notify.connect(self.slideshow_enabled.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(self.slideshow_order.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(self.slideshow_transition.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(self.slideshow_interval, *View, spun, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(self.slideshow_duration, *View, spun, self, .{});
        _ = gtk.Editable.signals.changed.connect(self.slideshow_folder.as(gtk.Editable), *View, edited, self, .{});
        self.raw_insert_signal = gtk.TextBuffer.signals.insert_text.connect(self.raw, *View, inserting, self, .{});
        self.raw_changed_signal = gtk.TextBuffer.signals.changed.connect(self.raw, *View, rawEdited, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.filling = true;
        self.language_arena.deinit();
        self.themes.destroy();
        self.profiles.destroy();
        self.greeter_sync.destroy();
        self.closePicker();
        self.closeFolderPicker();
        if (self.preview_idle != 0) _ = glib.Source.remove(self.preview_idle);
        if (self.palette_idle != 0) _ = glib.Source.remove(self.palette_idle);
        self.palette_idle = 0;
        self.cancelPreview();
        self.desktop_preview.destroy();
        gtk.StyleContext.removeProviderForDisplay(self.window.as(gtk.Widget).getDisplay(), self.preview_css.as(gtk.StyleProvider));
        self.preview_css.unref();
        if (self.shown) |s| a.free(s);
        if (self.preview_key) |s| a.free(s);
        if (self.palette_key) |s| a.free(s);
        self.arena.deinit();
        // Widget destruction disconnects callbacks before this struct is freed.
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        // raw_view remains owned by the window until its destruction; disconnect
        // its buffer callbacks explicitly because the host destroys us first.
        object.signalHandlerDisconnect(self.raw.as(object.Object), self.raw_insert_signal);
        object.signalHandlerDisconnect(self.raw.as(object.Object), self.raw_changed_signal);
        a.destroy(self);
    }
    fn syncPreferences(context: *anyopaque, alloc: std.mem.Allocator) !model.Preferences {
        const self: *View = @ptrCast(@alignCast(context));
        if (!self.editor.editable() or self.raw_invalid) return error.Unavailable;
        return model.parse(alloc, self.editor.text());
    }
    pub fn update(self: *View) void {
        self.night_status.setText(self.editor.night_summary.z());
        self.night_resume.as(gtk.Widget).setVisible(@intFromBool(self.editor.night_override));
        self.themes.update();
        self.profiles.update();
        const text_ = self.editor.text();
        const changed = self.shown == null or !std.mem.eql(u8, self.shown.?, text_);
        if (changed and !self.filling) {
            const copy = a.dupeSentinel(u8, text_, 0) catch return;
            if (self.shown) |old| a.free(old);
            self.shown = copy;
            self.filling = true;
            defer self.filling = false;
            self.raw.setText(copy, @intCast(copy.len));
            var arena = std.heap.ArenaAllocator.init(a);
            const parsed = model.parse(arena.allocator(), text_) catch null;
            if (parsed) |prefs| {
                self.arena.deinit();
                self.arena = arena;
                self.prefs = prefs;
                self.raw_invalid = false;
                if (!self.editing_form) self.fill(prefs);
            } else {
                arena.deinit();
                if (!self.editing_form) self.raw_invalid = true;
            }
            self.queuePreview();
        }
        self.qt_status.setText(self.editor.qt_summary.z());
        self.qt_comparison.setText(self.editor.qt_review_text.z());
        self.qt_reapply.as(gtk.Widget).setVisible(@intFromBool(self.editor.qt_review_digest.len == 64 and self.editor.qt_review_text.len != 0));
        for (self.night_times) |control| control.as(gtk.Widget).setSensitive(@intFromBool(self.night_schedule.getSelected() == 1));
        const slideshow_on = self.slideshow_enabled.getActive() != 0;
        for ([_]*gtk.Widget{ self.slideshow_folder.as(gtk.Widget), self.slideshow_choose.as(gtk.Widget), self.slideshow_interval.as(gtk.Widget), self.slideshow_order.as(gtk.Widget), self.slideshow_transition.as(gtk.Widget), self.slideshow_duration.as(gtk.Widget) }) |control| control.setSensitive(@intFromBool(slideshow_on));
        const editable = self.editor.editable();
        self.host.as(gtk.Widget).setSensitive(@intFromBool(editable and !self.raw_invalid));
        self.raw_view.setEditable(@intFromBool(self.editor.online and self.editor.ready and !self.editor.state.locked and self.editor.download == .none));
        self.raw_view.as(gtk.Widget).setSensitive(@intFromBool(self.editor.ready));
        self.source.as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 1));
        self.entries[0].as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 2));
        self.entries[1].as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 1 and self.source.getSelected() == 0));
        showRow(self.source.as(gtk.Widget), self.mode.getSelected() == 1);
        showRow(self.entries[0].as(gtk.Widget), self.mode.getSelected() == 2);
        showRow(self.entries[1].as(gtk.Widget), self.mode.getSelected() == 1 and self.source.getSelected() == 0);
        self.mode_hint.as(gtk.Widget).setVisible(@intFromBool(self.mode.getSelected() != 0));
        self.mode_hint.setText(if (self.mode.getSelected() == 2) @import("i18n").dtr("pearl", "An empty GTK theme name follows the system.") else if (self.mode.getSelected() == 3) @import("i18n").dtr("pearl", "Select an installed community theme below.") else @import("i18n").dtr("pearl", "Dynamic colors need matugen 4.x."));
        self.message.setText(if (self.raw_invalid) @import("i18n").dtr("pearl", "Advanced JSON is invalid. Correct it there to use these controls.") else "");
        self.message.as(gtk.Widget).setVisible(@intFromBool(self.raw_invalid));
        self.customize.as(gtk.Widget).setVisible(@intFromBool(self.mode.getSelected() == 3));
        self.presentation();
        self.queuePreview();
        self.queuePalettePreview();
    }
    fn presentation(self: *View) void {
        if (self.raw_invalid) return;
        const p = self.prefs;
        if (self.editor.target.page == .appearance) self.desktop_preview.update(p);
        if (self.themes.preview_is_draft and self.editor.theme_error.len > 0 and !self.themes.preview_cancel_requested) self.desktop_preview.status.setText(self.editor.theme_error.z());
        var buf: [1024]u8 = undefined;
        self.text_section.summary.setText(std.mem.printSentinel(&buf, "{s} · {d} px · {s}{s}", .{ if (p.font.len == 0) @import("i18n").dtr("pearl", "System font") else p.font, p.font_size, if (p.density == .compact) @import("i18n").dtr("pearl", "Compact") else @import("i18n").dtr("pearl", "Comfortable"), if (p.reduced_motion) @import("i18n").dtr("pearl", " · Reduced motion") else "" }, 0) catch "");
        self.desktop_section.summary.setText(std.mem.printSentinel(&buf, "{s} · {d} px · {s}", .{ if (p.desktop_icons.enabled) @import("i18n").dtr("pearl", "On") else @import("i18n").dtr("pearl", "Off"), p.desktop_icons.icon_size, if (@backingInt(p.desktop_icons.arrangement) == 0) @import("i18n").dtr("pearl", "Automatic arrangement") else @import("i18n").dtr("pearl", "Manual arrangement") }, 0) catch "");
        const night_summary = self.editor.night_summary.slice();
        self.night_section.summary.setText(if (night_summary.len > 0) std.mem.printSentinel(&buf, "{s}", .{night_summary[0 .. std.mem.indexOfScalar(u8, night_summary, '\n') orelse night_summary.len]}, 0) catch "" else if (p.night_light.enabled) @import("i18n").dtr("pearl", "On · warmer screen colors") else @import("i18n").dtr("pearl", "Off · warmer screen colors on supported displays"));
        var qt_attention = false;
        for ([_][]const u8{ "failed", "conflict", "missing_dependency", "restore_incomplete", "Restart", "Log in" }) |needle| if (std.mem.indexOf(u8, self.editor.qt_summary.slice(), needle) != null) {
            qt_attention = true;
            break;
        };
        self.apps_section.summary.setText(if (self.editor.qt_review_text.len > 0) @import("i18n").dtr("pearl", "External Qt changes need review") else if (qt_attention) @import("i18n").dtr("pearl", "Qt needs attention · expand to review status") else @import("i18n").dtr("pearl", "Window borders, Qt and application colors"));
        self.themes_section.summary.setText(if (self.editor.theme_error.len > 0 and !self.editor.application_command) self.editor.theme_error.z() else std.mem.span(self.themes.selection.getText()));
        if (self.editor.application_command and self.editor.theme_error.len > 0) self.apps_section.summary.setText(self.editor.theme_error.z());
        self.login_section.summary.setText(std.mem.span(self.greeter_sync.status.getText()));
        const fit_names: [4][:0]const u8 = .{ @import("i18n").dtr("pearl", "Material gradient"), @import("i18n").dtr("pearl", "Solid color"), @import("i18n").dtr("pearl", "Cover"), @import("i18n").dtr("pearl", "Contain") };
        const fit_name = fit_names[@backingInt(p.wallpaper.mode)];
        const filename = if (p.wallpaper.path.len > 0) std.fs.path.basename(p.wallpaper.path) else @import("i18n").dtr("pearl", "No image selected");
        self.wallpaper_summary.setText(if (@backingInt(p.wallpaper.mode) < 2) fit_name else std.mem.printSentinel(&buf, "{s}\n{s}", .{ filename, fit_name }, 0) catch fit_name);
        self.image_section.summary.setText(if (p.wallpaper.slideshow.enabled) @import("i18n").dtr("pearl", "Slideshow on · path, fit and timing") else @import("i18n").dtr("pearl", "Slideshow off · path, fit and background color"));
    }
    fn modeChosen(button: *gtk.CheckButton, self: *View) callconv(.c) void {
        if (button.getActive() == 0 or self.filling) return;
        // Community needs a concrete selection. Keep the valid current draft
        // while opening its picker, rather than stranding it in an invalid mode.
        if (self.mode.getSelected() == 3 and self.prefs.theme.package_id.len == 0 and self.prefs.theme.palette_id.len == 0) {
            self.filling = true;
            self.mode.setSelected(@backingInt(self.prefs.theme.mode));
            self.filling = false;
            self.themes_section.expander.setExpanded(1);
            _ = self.themes_section.expander.as(gtk.Widget).grabFocus();
            return;
        }
        self.saveForm();
        if (self.mode.getSelected() == 3) self.themes_section.expander.setExpanded(1);
    }
    fn openThemes(_: *gtk.Button, self: *View) callconv(.c) void {
        self.themes_section.expander.setExpanded(1);
        _ = self.themes_section.expander.as(gtk.Widget).grabFocus();
    }
    fn previewPalette(context: *anyopaque, palette: ?@import("../theme/theme.zig").Palette) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.desktop_preview.palette(palette, self.prefs.theme.mode == .gtk);
    }
    fn fill(self: *View, prefs: model.Preferences) void {
        var language_index: ?usize = null;
        for (self.language_codes.items, 0..) |code, i| if (std.mem.eql(u8, code, prefs.language)) {
            language_index = i;
            break;
        };
        if (language_index == null) {
            const alloc = self.language_arena.allocator();
            const code = alloc.dupeSentinel(u8, prefs.language, 0) catch return;
            const label = @import("i18n").fmtAlloc(alloc, "{s} (language pack not installed)", .{code}) catch return;
            language_index = self.language_codes.items.len;
            self.language_codes.append(alloc, code) catch return;
            object.ext.cast(gtk.StringList, self.language.getModel().?).?.append(label);
        }
        self.language.setSelected(@intCast(language_index.?));
        self.desktop_enabled.setActive(@intFromBool(prefs.desktop_icons.enabled));
        self.desktop_hidden.setActive(@intFromBool(prefs.desktop_icons.show_hidden));
        self.desktop_output.as(gtk.Editable).setText(self.arena.allocator().dupeSentinel(u8, prefs.desktop_icons.output, 0) catch "");
        self.desktop_size.setSelected(@intCast(std.mem.indexOfScalar(u16, &@import("../desktop/icons/model.zig").sizes, prefs.desktop_icons.icon_size) orelse 1));
        self.desktop_arrangement.setSelected(@backingInt(prefs.desktop_icons.arrangement));
        self.night_enabled.setActive(@intFromBool(prefs.night_light.enabled));
        self.night_temperature.setValue(@floatFromInt(prefs.night_light.temperature_kelvin));
        self.night_schedule.setSelected(@backingInt(prefs.night_light.schedule));
        const night_times = [_]u16{ prefs.night_light.start_minute / 60, prefs.night_light.start_minute % 60, prefs.night_light.end_minute / 60, prefs.night_light.end_minute % 60 };
        for (self.night_times, night_times) |control, number| control.setValue(@floatFromInt(number));
        self.mode.setSelected(switch (prefs.theme.mode) {
            .static => 0,
            .dynamic => 1,
            .gtk => 2,
            .package => 3,
        });
        self.sync_borders.setActive(@intFromBool(prefs.theme.sync_borders));
        self.variant.setSelected(@backingInt(prefs.theme.variant));
        self.source.setSelected(@backingInt(prefs.theme.source));
        self.scheme.setSelected(@backingInt(prefs.theme.scheme));
        self.fit.setSelected(@backingInt(prefs.wallpaper.mode));
        self.slideshow_enabled.setActive(@intFromBool(prefs.wallpaper.slideshow.enabled));
        self.slideshow_folder.as(gtk.Editable).setText(self.arena.allocator().dupeSentinel(u8, prefs.wallpaper.slideshow.folder, 0) catch "");
        self.slideshow_interval.setValue(@floatFromInt(prefs.wallpaper.slideshow.interval_seconds));
        self.slideshow_order.setSelected(@backingInt(prefs.wallpaper.slideshow.order));
        self.slideshow_transition.setSelected(@backingInt(prefs.wallpaper.slideshow.transition));
        self.slideshow_duration.setValue(@floatFromInt(prefs.wallpaper.slideshow.transition_ms));
        self.density.setSelected(@backingInt(prefs.density));
        for (self.entries, [_][]const u8{ prefs.theme.gtk_name, prefs.theme.seed, prefs.wallpaper.path, prefs.wallpaper.color, prefs.font }) |control, value| control.as(gtk.Editable).setText(self.arena.allocator().dupeSentinel(u8, value, 0) catch "");
        self.font_size.setValue(@floatFromInt(prefs.font_size));
        self.motion.setActive(@intFromBool(prefs.reduced_motion));
        self.qt_enabled.setActive(@intFromBool(prefs.qt.enabled));
        self.qt5.setActive(@intFromBool(prefs.qt.targets.qt5));
        self.qt6.setActive(@intFromBool(prefs.qt.targets.qt6));
        self.qt_palette.setSelected(@backingInt(prefs.qt.palette));
        self.qt_font.setActive(@intFromBool(prefs.qt.sync_font));
        self.qt_icon.as(gtk.Editable).setText(self.arena.allocator().dupeSentinel(u8, prefs.qt.icon_theme, 0) catch "");
        self.qt_radius.setValue(@floatFromInt(prefs.qt.darkly.corner_radius orelse 0));
        self.qt_motion.setActive(@intFromBool(prefs.qt.darkly.sync_reduced_motion));
        self.qt_kde.setActive(@intFromBool(prefs.qt.darkly.sync_kde_colors));
        self.qt_density.setActive(@intFromBool(prefs.qt.darkly.sync_density));
    }
    fn saveForm(self: *View) void {
        if (self.filling or !self.editor.editable()) return;
        var prefs = self.prefs;
        prefs.desktop_icons = .{ .enabled = self.desktop_enabled.getActive() != 0, .show_hidden = self.desktop_hidden.getActive() != 0, .output = text(self.desktop_output), .icon_size = @import("../desktop/icons/model.zig").sizes[@min(3, self.desktop_size.getSelected())], .arrangement = @fromBackingInt(@intCast(self.desktop_arrangement.getSelected())) };
        prefs.night_light = .{
            .enabled = self.night_enabled.getActive() != 0,
            .temperature_kelvin = @intCast(self.night_temperature.getValueAsInt()),
            .schedule = @fromBackingInt(@intCast(self.night_schedule.getSelected())),
            .start_minute = @intCast(self.night_times[0].getValueAsInt() * 60 + self.night_times[1].getValueAsInt()),
            .end_minute = @intCast(self.night_times[2].getValueAsInt() * 60 + self.night_times[3].getValueAsInt()),
        };
        prefs.theme.mode = switch (self.mode.getSelected()) {
            1 => .dynamic,
            2 => .gtk,
            3 => .package,
            else => .static,
        };
        prefs.theme.sync_borders = self.sync_borders.getActive() != 0;
        prefs.theme.variant = @fromBackingInt(@intCast(self.variant.getSelected()));
        prefs.theme.source = @fromBackingInt(@intCast(self.source.getSelected()));
        prefs.theme.scheme = @fromBackingInt(@intCast(self.scheme.getSelected()));
        prefs.theme.gtk_name = text(self.entries[0]);
        prefs.theme.seed = text(self.entries[1]);
        // A rotating image is only visible in an image fit, so enabling the
        // slideshow moves a gradient or solid fit to cover rather than failing.
        const slideshow_on = self.slideshow_enabled.getActive() != 0;
        const chosen_fit = self.fit.getSelected();
        prefs.wallpaper = .{
            .mode = @fromBackingInt(@intCast(if (slideshow_on and chosen_fit != 2 and chosen_fit != 3) @as(c_uint, 2) else chosen_fit)),
            .path = text(self.entries[2]),
            .color = text(self.entries[3]),
            // The form has no crop editor, so a save must not drop placements
            // the shell recorded for other images.
            .crops = prefs.wallpaper.crops,
            .slideshow = .{
                .enabled = slideshow_on,
                .folder = text(self.slideshow_folder),
                .interval_seconds = @intCast(self.slideshow_interval.getValueAsInt()),
                .order = @fromBackingInt(@intCast(self.slideshow_order.getSelected())),
                .transition = @fromBackingInt(@intCast(self.slideshow_transition.getSelected())),
                .transition_ms = @intCast(self.slideshow_duration.getValueAsInt()),
            },
        };
        prefs.font = text(self.entries[4]);
        prefs.language = self.language_codes.items[@min(self.language.getSelected(), self.language_codes.items.len - 1)];
        prefs.font_size = @intCast(self.font_size.getValueAsInt());
        prefs.density = @fromBackingInt(@intCast(self.density.getSelected()));
        prefs.reduced_motion = self.motion.getActive() != 0;
        prefs.qt.enabled = self.qt_enabled.getActive() != 0;
        prefs.qt.targets = .{ .qt5 = self.qt5.getActive() != 0, .qt6 = self.qt6.getActive() != 0 };
        prefs.qt.palette = @fromBackingInt(@intCast(self.qt_palette.getSelected()));
        prefs.qt.sync_font = self.qt_font.getActive() != 0;
        prefs.qt.icon_theme = text(self.qt_icon);
        const radius = self.qt_radius.getValueAsInt();
        prefs.qt.darkly.corner_radius = if (radius == 0) null else @intCast(radius);
        prefs.qt.darkly.sync_reduced_motion = self.qt_motion.getActive() != 0;
        prefs.qt.darkly.sync_kde_colors = self.qt_kde.getActive() != 0;
        prefs.qt.darkly.sync_density = self.qt_density.getActive() != 0;
        const json = std.json.Stringify.valueAlloc(a, prefs, .{ .whitespace = .indent_2 }) catch {
            self.rejectForm();
            return;
        };
        defer a.free(json);
        self.editing_form = true;
        defer self.editing_form = false;
        self.editor.edit(json) catch {
            self.rejectForm();
        };
    }
    fn rejectForm(self: *View) void {
        self.filling = true;
        self.fill(self.prefs);
        self.filling = false;
        self.editor.error_code.set("OutOfMemory");
        self.editor.notify(self.editor.context, .changed);
    }
    fn resumeNight(_: *gtk.Button, self: *View) callconv(.c) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const params = std.json.Stringify.valueAlloc(alloc, .{ .generation = @import("editor_protocol.zig").num(self.editor.night_generation), .action = "resume" }, .{}) catch return;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, params, .{}) catch return;
        self.editor.liveAction(.@"night-light.action", value) catch |err| {
            self.editor.error_code.set(@errorName(err));
        };
    }
    fn retryQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.retry");
    }
    fn reviewQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.review");
    }
    fn reapplyQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.reapply");
    }
    fn edited(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn spun(_: *gtk.SpinButton, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn inserting(buffer: *gtk.TextBuffer, _: *gtk.TextIter, _: [*:0]u8, length: c_int, self: *View) callconv(.c) void {
        if (self.filling) return;
        const bytes = rawText(buffer);
        defer glib.free(bytes);
        if (length < 0 or std.mem.span(bytes).len + @as(usize, @intCast(length)) > model.max_bytes) {
            object.signalStopEmissionByName(buffer.as(object.Object), "insert-text");
            self.editor.error_code.set("DocumentTooLarge");
            self.editor.notify(self.editor.context, .changed);
        }
    }
    fn rawEdited(buffer: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (self.filling) return;
        const bytes = rawText(buffer);
        defer glib.free(bytes);
        // Avoid resetting the buffer/selection during its own changed signal.
        self.filling = true;
        self.editor.edit(std.mem.span(bytes)) catch |err| {
            // Reject visibly: never leave GTK text that the coordinator cannot
            // flush on close. An explicit byte count permits the borrowed slice.
            const previous = self.editor.text();
            buffer.setText(@ptrCast(previous.ptr), @intCast(previous.len));
            self.filling = false;
            self.editor.error_code.set(@errorName(err));
            self.editor.notify(self.editor.context, .changed);
            return;
        };
        self.filling = false;
        if (self.shown) |old| a.free(old);
        self.shown = a.dupeSentinel(u8, std.mem.span(bytes), 0) catch null;
        var arena = std.heap.ArenaAllocator.init(a);
        const prefs = model.parse(arena.allocator(), std.mem.span(bytes)) catch null;
        if (prefs) |value| {
            self.arena.deinit();
            self.arena = arena;
            self.prefs = value;
            self.filling = true;
            self.fill(value);
            self.filling = false;
            self.raw_invalid = false;
            self.queuePreview();
        } else {
            arena.deinit();
            self.raw_invalid = true;
        }
        self.update();
    }
    pub fn closePicker(self: *View) void {
        if (self.picker) |picker| {
            self.picker = null;
            picker.as(gtk.Window).destroy();
            picker.unref();
        }
    }
    fn chooseWallpaper(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        if (self.picker) |picker| {
            picker.as(gtk.Window).present();
            return;
        }
        const picker = files.create(@import("i18n").dtr("pearl", "Choose wallpaper image"), .open);
        files.setStateKey(picker, "first-party/wallpaper-image");
        self.picker = picker;
        _ = picker.ref();
        const window = picker.as(gtk.Window);
        window.setTransientFor(self.window);
        window.setModal(1);
        window.setDefaultSize(1040, 680);
        files.setLocalOnly(picker, 1);
        const dialog = picker.as(gtk.Dialog);
        const filter = gtk.FileFilter.new();
        filter.setName("PNG and JPEG images");
        filter.addMimeType("image/png");
        filter.addMimeType("image/jpeg");
        files.addFilter(picker, filter);
        filter.unref();
        const current = self.entries[2].as(gtk.Editable).getText();
        if (current[0] == '/') {
            const file = gio.File.newForPath(current);
            defer file.unref();
            files.setFile(picker, file);
        }
        _ = gtk.Dialog.signals.response.connect(dialog, *View, wallpaperChosen, self, .{});
        window.present();
    }
    fn wallpaperChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer self.closePicker();
        if (response != @backingInt(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = files.getFile(dialog) orelse return;
        defer file.unref();
        const path = file.getPath() orelse {
            self.message.setText(@import("i18n").dtr("pearl", "Choose an image stored on this computer."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        };
        defer glib.free(path);
        if (std.mem.span(path).len > 1024 or !std.unicode.utf8ValidateSlice(std.mem.span(path))) {
            self.message.setText(@import("i18n").dtr("pearl", "The image path is too long or is not valid UTF-8."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        }
        self.filling = true;
        self.entries[2].as(gtk.Editable).setText(path);
        self.fit.setSelected(@backingInt(@as(model.Wallpaper, .{ .mode = .cover }).mode));
        self.filling = false;
        self.saveForm();
    }
    pub fn closeFolderPicker(self: *View) void {
        if (self.folder_picker) |picker| {
            self.folder_picker = null;
            picker.as(gtk.Window).destroy();
            picker.unref();
        }
    }
    fn chooseFolder(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        if (self.folder_picker) |picker| {
            picker.as(gtk.Window).present();
            return;
        }
        const picker = files.create(@import("i18n").dtr("pearl", "Choose wallpaper folder"), .select_folder);
        files.setStateKey(picker, "first-party/wallpaper-folder");
        self.folder_picker = picker;
        _ = picker.ref();
        const window = picker.as(gtk.Window);
        window.setTransientFor(self.window);
        window.setModal(1);
        window.setDefaultSize(1040, 680);
        files.setLocalOnly(picker, 1);
        const dialog = picker.as(gtk.Dialog);
        const current = self.slideshow_folder.as(gtk.Editable).getText();
        if (current[0] == '/') {
            const file = gio.File.newForPath(current);
            defer file.unref();
            files.setFile(picker, file);
        }
        _ = gtk.Dialog.signals.response.connect(dialog, *View, folderChosen, self, .{});
        window.present();
    }
    fn folderChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer self.closeFolderPicker();
        if (response != @backingInt(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = files.getFile(dialog) orelse return;
        defer file.unref();
        const path = file.getPath() orelse {
            self.message.setText(@import("i18n").dtr("pearl", "Choose a folder stored on this computer."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        };
        defer glib.free(path);
        const folder = std.mem.span(path);
        if (folder.len > 1024 or !std.unicode.utf8ValidateSlice(folder)) {
            self.message.setText(@import("i18n").dtr("pearl", "The folder path is too long or is not valid UTF-8."));
            self.message.as(gtk.Widget).setVisible(1);
            return;
        }
        self.filling = true;
        self.slideshow_folder.as(gtk.Editable).setText(path);
        // Validation needs an image fit and an initial image once the slideshow runs.
        if (self.fit.getSelected() != 2 and self.fit.getSelected() != 3) self.fit.setSelected(@backingInt(@as(model.Wallpaper, .{ .mode = .cover }).mode));
        if (self.entries[2].as(gtk.Editable).getText()[0] != '/') {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            if (@import("../config/slideshow.zig").firstImage(arena.allocator(), folder)) |first| self.entries[2].as(gtk.Editable).setText(first.ptr);
        }
        self.filling = false;
        self.saveForm();
    }
    fn cancelPreview(self: *View) void {
        if (self.preview) |preview| {
            self.preview = null;
            preview.owner = null;
            preview.cancel.cancel();
        }
    }
    fn queuePreview(self: *View) void {
        if (self.editor.target.page != .appearance or self.raw_invalid) {
            if (self.preview_idle != 0) _ = glib.Source.remove(self.preview_idle);
            self.preview_idle = 0;
            if (self.preview != null) {
                self.cancelPreview();
                if (self.preview_key) |key| a.free(key);
                self.preview_key = null;
            }
            return;
        }
        const key = std.fmt.allocPrint(a, "{d}:{s}:{s}", .{ self.fit.getSelected(), text(self.entries[3]), text(self.entries[2]) }) catch return;
        defer a.free(key);
        if (self.preview_key) |old| if (std.mem.eql(u8, old, key)) return;
        // A superseded decoder must lose its owner immediately, including during
        // the debounce window. Its completion only releases its own resources.
        if (self.preview != null) {
            self.cancelPreview();
            if (self.preview_key) |old| a.free(old);
            self.preview_key = null;
        }
        if (self.preview_idle == 0) self.preview_idle = glib.timeoutAdd(150, refreshPreview, self);
    }
    fn paletteKey(self: *View) ?[]u8 {
        const p = self.prefs;
        return std.fmt.allocPrint(a, "{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}", .{ @tagName(p.theme.mode), @tagName(p.theme.variant), @tagName(p.theme.source), @tagName(p.theme.scheme), p.theme.seed, p.theme.package_id, p.theme.palette_id, p.theme.style_id, p.wallpaper.path }) catch null;
    }
    fn setPaletteKey(self: *View, key: []const u8) void {
        if (self.palette_key) |old| a.free(old);
        self.palette_key = a.dupe(u8, key) catch null;
    }
    /// The mini desktop preview renders through the themes helper, so draft
    /// color inputs (dynamic seed, source, package picks) re-render it
    /// debounced instead of waiting for the manual Preview button.
    fn queuePalettePreview(self: *View) void {
        if (self.palette_idle != 0) _ = glib.Source.remove(self.palette_idle);
        self.palette_idle = 0;
        if (self.raw_invalid) return;
        const key = self.paletteKey() orelse return;
        defer a.free(key);
        if (self.prefs.theme.mode == .gtk) {
            self.setPaletteKey(key);
            self.desktop_preview.palette(null, true);
            return;
        }
        if (self.palette_key) |old| if (std.mem.eql(u8, old, key)) return;
        self.palette_idle = glib.timeoutAdd(300, paletteIdle, self);
    }
    fn paletteIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.palette_idle = 0;
        if (self.editor.target.page != .appearance or self.raw_invalid) return 0;
        if (self.prefs.theme.mode == .gtk) return 0;
        if (!self.editor.editable() or !self.editor.client.capabilities.community_themes) return 0;
        if (self.editor.theme_busy) {
            self.palette_idle = glib.timeoutAdd(500, paletteIdle, self);
            return 0;
        }
        const key = self.paletteKey() orelse return 0;
        defer a.free(key);
        self.setPaletteKey(key);
        self.desktop_preview.status.setText(@import("i18n").dtr("pearl", "Rendering draft colors…"));
        self.themes.previewDraft() catch |err| {
            self.desktop_preview.status.setText(@errorName(err));
        };
        return 0;
    }
    fn refreshPreview(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.preview_idle = 0;
        const path = text(self.entries[2]);
        const mode = self.fit.getSelected();
        const color = text(self.entries[3]);
        const key = std.fmt.allocPrint(a, "{d}:{s}:{s}", .{ mode, color, path }) catch return 0;
        if (self.preview_key) |old| if (std.mem.eql(u8, old, key)) {
            a.free(key);
            return 0;
        };
        if (self.preview_key) |old| a.free(old);
        self.preview_key = key;
        self.cancelPreview();
        self.preview_ready = false;
        self.picture.setPaintable(null);
        self.wallpaper_thumbnail.setPaintable(null);
        self.picture.setContentFit(if (mode == 3) .contain else .cover);
        self.wallpaper_thumbnail.setContentFit(if (mode == 3) .contain else .cover);
        const css = std.fmt.allocPrintSentinel(a, ".settings-window .appearance-view .settings-draft-preview {{ background: {s}; }}", .{if (mode == 0) "linear-gradient(155deg, #211a2b, #9576b5)" else if (model.hex(color)) color else "#141218"}, 0) catch return 0;
        defer a.free(css);
        self.preview_css.loadFromString(css);
        self.preview_note.setText(@import("i18n").dtr("pearl", "Draft preview · Changes take effect after Apply & save."));
        if (mode < 2 or path.len == 0 or path[0] != '/') return 0;
        const z = a.dupeSentinel(u8, path, 0) catch return 0;
        defer a.free(z);
        const preview = a.create(Preview) catch return 0;
        self.preview_note.setText(@import("i18n").dtr("pearl", "Loading wallpaper preview…"));
        preview.* = .{ .owner = self, .file = gio.File.newForPath(z), .cancel = gio.Cancellable.new() };
        self.preview = preview;
        preview.file.readAsync(0, preview.cancel, Preview.opened, preview);
        return 0;
    }
};
const Preview = struct {
    owner: ?*View,
    file: *gio.File,
    cancel: *gio.Cancellable,
    stream: ?*gio.InputStream = null,
    fn destroy(self: *Preview) void {
        if (self.stream) |stream| {
            _ = stream.close(null, null);
            stream.unref();
        }
        self.file.unref();
        self.cancel.unref();
        a.destroy(self);
    }
    fn failed(self: *Preview) void {
        if (self.owner) |owner| {
            owner.preview = null;
            owner.preview_note.setText(@import("i18n").dtr("pearl", "Could not preview this image. Apply will validate the file."));
        }
        self.destroy();
    }
    fn opened(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Preview = @ptrCast(@alignCast(data.?));
        const stream = self.file.readFinish(result, null) orelse {
            self.failed();
            return;
        };
        self.stream = stream.as(gio.InputStream);
        if (self.owner == null) {
            self.destroy();
            return;
        }
        pixbuf.Pixbuf.newFromStreamAtScaleAsync(self.stream.?, 720, 200, 1, self.cancel, decoded, self);
    }
    fn decoded(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Preview = @ptrCast(@alignCast(data.?));
        const image = pixbuf.Pixbuf.newFromStreamFinish(result, null) orelse {
            self.failed();
            return;
        };
        defer image.unref();
        if (self.owner) |owner| {
            const texture = gdk.Texture.newForPixbuf(image);
            defer texture.unref();
            owner.picture.setPaintable(texture.as(gdk.Paintable));
            owner.wallpaper_thumbnail.setPaintable(texture.as(gdk.Paintable));
            owner.preview_note.setText(@import("i18n").dtr("pearl", "Wallpaper draft preview · Changes take effect after Apply & save."));
            owner.preview_ready = true;
            owner.preview = null;
        }
        self.destroy();
    }
};
fn rawText(buffer: *gtk.TextBuffer) [*:0]u8 {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    return buffer.getText(&start, &end, 1);
}
fn text(entry_: *gtk.Entry) []const u8 {
    return std.mem.span(entry_.as(gtk.Editable).getText());
}
fn card(host: *gtk.Box) *gtk.Box {
    const box = w.column(0);
    box.as(gtk.Widget).addCssClass("settings-card");
    host.append(box.as(gtk.Widget));
    return box;
}
fn row(host: *gtk.Box, title: [:0]const u8, control: *gtk.Widget) void {
    const box = gtk.FlowBox.new();
    box.setSelectionMode(.none);
    box.setHomogeneous(0);
    box.setMinChildrenPerLine(1);
    box.setMaxChildrenPerLine(2);
    box.setColumnSpacing(16);
    box.setRowSpacing(8);
    box.as(gtk.Widget).addCssClass("settings-form-row");
    const label = w.label(title, "settings-row-title");
    box.insert(label.as(gtk.Widget), -1);
    control.setHalign(.end);
    control.setValign(.center);
    w.name(control, title);
    box.insert(control, -1);
    host.append(box.as(gtk.Widget));
}
fn showRow(control: *gtk.Widget, visible: bool) void {
    // Every form control is wrapped by a FlowBoxChild in its own form row.
    control.getParent().?.getParent().?.setVisible(@intFromBool(visible));
}
fn entry(host: *gtk.Box, title: [:0]const u8, max: c_int) *gtk.Entry {
    const control = gtk.Entry.new();
    control.setMaxLength(max);
    control.as(gtk.Editable).setWidthChars(16);
    control.as(gtk.Editable).setMaxWidthChars(24);
    row(host, title, control.as(gtk.Widget));
    return control;
}
fn dropdown(host: *gtk.Box, title: [:0]const u8, choices: []const [*:0]const u8) *gtk.DropDown {
    // Room for the longest choice list plus the NULL terminator newFromStrings needs.
    var strings: [16]?[*:0]const u8 = @splat(null);
    for (choices, 0..) |choice, i| strings[i] = choice;
    const control = gtk.DropDown.newFromStrings(@ptrCast(&strings));
    row(host, title, control.as(gtk.Widget));
    return control;
}

fn toggle(host: *gtk.Box, title: [:0]const u8) *gtk.Switch {
    const control = gtk.Switch.new();
    row(host, title, control.as(gtk.Widget));
    return control;
}
