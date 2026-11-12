//! GTK4 GtkDrawingArea terminal surface: a Cairo/Pango renderer driven entirely
//! by libghostty-vt render state (rows/cells/styles/colors/cursor/selection),
//! plus key/mouse/paste/selection input routed through the ghostty encoders.
//! libghostty-vt holds VT state only; this file draws and translates input. The
//! PTY is owned by terminal_controller.zig and reached through Hooks. Terminal
//! output never dispatches actions: title/pwd callbacks only update labels.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const g = @import("ghostty.zig");

pub const Hooks = struct {
    context: *anyopaque,
    /// Nonblocking PTY write; may be called from ghostty effects during vt_write.
    write_pty: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// Mirror a grid resize onto the PTY (TIOCSWINSZ).
    resize_pty: *const fn (ctx: *anyopaque, cols: u16, rows: u16) void,
    title_changed: ?*const fn (ctx: *anyopaque, title: []const u8) void = null,
    pwd_changed: ?*const fn (ctx: *anyopaque, pwd: []const u8) void = null,
    bell: ?*const fn (ctx: *anyopaque) void = null,
};

const font_family = "Monospace";
const font_size_pt: c_int = 11;

/// Heap context for an async clipboard paste. It is owned by the GCancellable
/// (via g_object_set_data_full) and kept alive during the callback by an extra
/// cancellable ref, so it outlives the Surface. `cancelled` is set by
/// Surface.deinit before the Surface is freed; pasteReady checks it and never
/// dereferences `surface` once set.
const PasteCtx = struct {
    surface: *Surface,
    cancel: *c.GCancellable,
    cancelled: bool,
};

fn freePasteCtx(data: ?*anyopaque) callconv(.c) void {
    const ctx: *PasteCtx = @ptrCast(@alignCast(data.?));
    a.destroy(ctx);
}

pub const Surface = struct {
    widget: u.W,
    terminal: *g.Terminal,
    render: *g.RenderState,
    rows: *g.RowIterator,
    cells: *g.RowCells,
    key_encoder: *g.KeyEncoder,
    key_event: *g.KeyEvent,
    mouse_encoder: *g.MouseEncoder,
    mouse_event: *g.MouseEvent,
    hooks: Hooks,
    cell_width: u32,
    cell_height: u32,
    cols: u16,
    rows_count: u16,
    font: *c.PangoFontDescription,
    font_bold: *c.PangoFontDescription,
    font_italic: *c.PangoFontDescription,
    font_bold_italic: *c.PangoFontDescription,
    tick_id: c_uint = 0,
    last_alloc_width: c_int = -1,
    last_alloc_height: c_int = -1,
    controllers: [8]*c.GtkEventController = undefined,
    controller_count: usize = 0,
    closed: bool = false,
    // Selection drag state (viewport cell coordinates).
    selecting: bool = false,
    select_anchor: g.GridRef = .{ .node = null, .x = 0, .y = 0 },
    dragged: bool = false,
    // Transient paste payload borrowed by the synchronous mime reader.
    paste_bytes: []const u8 = &.{},
    paste_written: bool = false,
    // Async clipboard paste lifetime: the GCancellable anchors a heap PasteCtx
    // that outlives the Surface, so pasteReady never dereferences freed storage.
    paste_cancel: ?*c.GCancellable = null,
    paste_pending: bool = false,

    pub fn init(hooks: Hooks, cols: u16, rows: u16) !Surface {
        var terminal: ?*g.Terminal = null;
        if (!g.ok(g.ghostty_terminal_new(null, &terminal, cols, rows))) return error.TerminalCreate;
        errdefer g.ghostty_terminal_free(terminal);
        var render: ?*g.RenderState = null;
        if (!g.ok(g.ghostty_render_state_new(null, &render))) return error.RenderCreate;
        errdefer g.ghostty_render_state_free(render);
        var row_iter: ?*g.RowIterator = null;
        if (!g.ok(g.ghostty_render_state_row_iterator_new(null, &row_iter))) return error.IteratorCreate;
        errdefer g.ghostty_render_state_row_iterator_free(row_iter);
        var row_cells: ?*g.RowCells = null;
        if (!g.ok(g.ghostty_render_state_row_cells_new(null, &row_cells))) return error.CellsCreate;
        errdefer g.ghostty_render_state_row_cells_free(row_cells);
        var key_encoder: ?*g.KeyEncoder = null;
        if (!g.ok(g.ghostty_key_encoder_new(null, &key_encoder))) return error.KeyEncoderCreate;
        errdefer g.ghostty_key_encoder_free(key_encoder);
        var key_event: ?*g.KeyEvent = null;
        if (!g.ok(g.ghostty_key_event_new(null, &key_event))) return error.KeyEventCreate;
        errdefer g.ghostty_key_event_free(key_event);
        var mouse_encoder: ?*g.MouseEncoder = null;
        if (!g.ok(g.ghostty_mouse_encoder_new(null, &mouse_encoder))) return error.MouseEncoderCreate;
        errdefer g.ghostty_mouse_encoder_free(mouse_encoder);
        var mouse_event: ?*g.MouseEvent = null;
        if (!g.ok(g.ghostty_mouse_event_new(null, &mouse_event))) return error.MouseEventCreate;
        errdefer g.ghostty_mouse_event_free(mouse_event);

        const widget = c.gtk_drawing_area_new().?;
        _ = c.g_object_ref_sink(widget);
        errdefer c.g_object_unref(widget);
        c.gtk_widget_set_hexpand(widget, 1);
        c.gtk_widget_set_vexpand(widget, 1);
        c.gtk_widget_set_focusable(widget, 1);
        c.gtk_widget_add_css_class(widget, "terminal-surface");

        var self: Surface = .{
            .widget = widget,
            .terminal = terminal.?,
            .render = render.?,
            .rows = row_iter.?,
            .cells = row_cells.?,
            .key_encoder = key_encoder.?,
            .key_event = key_event.?,
            .mouse_encoder = mouse_encoder.?,
            .mouse_event = mouse_event.?,
            .hooks = hooks,
            .cell_width = 8,
            .cell_height = 16,
            .cols = cols,
            .rows_count = rows,
            .font = undefined,
            .font_bold = undefined,
            .font_italic = undefined,
            .font_bold_italic = undefined,
        };
        self.buildFonts();
        self.measure();
        _ = g.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.terminal);
        const alt_prefix = true;
        _ = g.ghostty_key_encoder_set(self.key_encoder, .alt_esc_prefix, &alt_prefix);
        _ = g.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.terminal);
        self.paste_cancel = c.g_cancellable_new();
        return self;
    }

    /// Safe OSC/effect policy. Clipboard read/write are denied by default;
    /// title/checksum reports, Kitty graphics storage, glyph protocol, desktop
    /// notifications and window-resize requests are disabled. Semantic metadata
    /// (title/pwd) may update labels but is never connected to action dispatch.
    fn configurePolicy(self: *Surface) void {
        const t = self.terminal;
        _ = g.ghostty_terminal_set(t, .userdata, @ptrCast(self));
        const write_pty: g.WritePtyFn = &onWritePty;
        _ = g.ghostty_terminal_set(t, .write_pty, @ptrCast(write_pty));
        const title_cb: g.TitleChangedFn = &onTitleChanged;
        _ = g.ghostty_terminal_set(t, .title_changed, @ptrCast(title_cb));
        const pwd_cb: g.PwdChangedFn = &onPwdChanged;
        _ = g.ghostty_terminal_set(t, .pwd_changed, @ptrCast(pwd_cb));
        const bell_cb: g.BellFn = &onBell;
        _ = g.ghostty_terminal_set(t, .bell, @ptrCast(bell_cb));
        const clip_write: g.ClipboardWriteFn = &onClipboardWrite;
        _ = g.ghostty_terminal_set(t, .clipboard_write, @ptrCast(clip_write));
        const clip_read: g.ClipboardReadFn = &onClipboardRead;
        _ = g.ghostty_terminal_set(t, .clipboard_read, @ptrCast(clip_read));
        const off = false;
        _ = g.ghostty_terminal_set(t, .title_report, &off);
        _ = g.ghostty_terminal_set(t, .xt_checksum_report, &off);
        _ = g.ghostty_terminal_set(t, .glyph_protocol, &off);
        const storage: u64 = 0;
        _ = g.ghostty_terminal_set(t, .kitty_image_storage_limit, &storage);
        _ = g.ghostty_terminal_set(t, .kitty_image_medium_file, &off);
        _ = g.ghostty_terminal_set(t, .kitty_image_medium_shared_mem, &off);
        // NULL callbacks ignore desktop notifications and window-resize requests.
        _ = g.ghostty_terminal_set(t, .desktop_notification, null);
        _ = g.ghostty_terminal_set(t, .resize_window, null);
        _ = g.ghostty_terminal_set(t, .progress_report, null);
        const scrollback: usize = 10 * 1024 * 1024;
        _ = g.ghostty_terminal_set(t, .scrollback_max_bytes, &scrollback);
        const lines: usize = 10000;
        _ = g.ghostty_terminal_set(t, .scrollback_max_lines, &lines);
    }

    fn buildFonts(self: *Surface) void {
        self.font = c.pango_font_description_new().?;
        c.pango_font_description_set_family(self.font, font_family);
        c.pango_font_description_set_size(self.font, font_size_pt * c.PANGO_SCALE);
        self.font_bold = c.pango_font_description_copy(self.font).?;
        c.pango_font_description_set_weight(self.font_bold, c.PANGO_WEIGHT_BOLD);
        self.font_italic = c.pango_font_description_copy(self.font).?;
        c.pango_font_description_set_style(self.font_italic, c.PANGO_STYLE_ITALIC);
        self.font_bold_italic = c.pango_font_description_copy(self.font).?;
        c.pango_font_description_set_weight(self.font_bold_italic, c.PANGO_WEIGHT_BOLD);
        c.pango_font_description_set_style(self.font_bold_italic, c.PANGO_STYLE_ITALIC);
    }

    fn measure(self: *Surface) void {
        const ctx = c.gtk_widget_get_pango_context(self.widget);
        const metrics = c.pango_context_get_metrics(ctx, self.font, null);
        const advance = c.pango_font_metrics_get_approximate_char_width(metrics);
        const ascent = c.pango_font_metrics_get_ascent(metrics);
        const descent = c.pango_font_metrics_get_descent(metrics);
        c.pango_font_metrics_unref(metrics);
        const scale = c.PANGO_SCALE;
        self.cell_width = @intCast(@max(1, @divTrunc(advance + scale - 1, scale)));
        self.cell_height = @intCast(@max(1, @divTrunc(ascent + descent + scale - 1, scale)));
    }

    /// Install controllers and ghostty effects once the surface is at its stable
    /// address. Callbacks capture `self`, so this must not run from init (which
    /// returns by value and would leave them pointing at a dead stack frame).
    pub fn attach(self: *Surface) void {
        self.configurePolicy();
        c.gtk_drawing_area_set_draw_func(u.cast(c.GtkDrawingArea, self.widget), &draw, self, null);
        const keys = c.gtk_event_controller_key_new().?;
        u.connect(keys, "key-pressed", &keyPressed, self);
        u.connect(keys, "key-released", &keyReleased, self);
        self.addController(keys);

        const click = c.gtk_gesture_click_new().?;
        c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, click), 0);
        u.connect(click, "pressed", &mousePressed, self);
        u.connect(click, "released", &mouseReleased, self);
        self.addController(u.cast(c.GtkEventController, click));

        const drag = c.gtk_gesture_drag_new().?;
        c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, drag), 1);
        u.connect(drag, "drag-begin", &dragBegin, self);
        u.connect(drag, "drag-update", &dragUpdate, self);
        u.connect(drag, "drag-end", &dragEnd, self);
        self.addController(u.cast(c.GtkEventController, drag));

        const scroll_ctrl = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL | c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE).?;
        u.connect(scroll_ctrl, "scroll", &scrolled, self);
        self.addController(u.cast(c.GtkEventController, scroll_ctrl));

        self.tick_id = c.gtk_widget_add_tick_callback(self.widget, &tick, self, null);
    }

    fn addController(self: *Surface, controller: *c.GtkEventController) void {
        self.controllers[self.controller_count] = controller;
        self.controller_count += 1;
        c.gtk_widget_add_controller(self.widget, controller);
    }

    pub fn focus(self: *Surface) void {
        _ = c.gtk_widget_grab_focus(self.widget);
    }

    pub fn queueDraw(self: *Surface) void {
        if (!self.closed) c.gtk_widget_queue_draw(self.widget);
    }

    /// Feed raw PTY bytes into the VT parser (GTK main thread only).
    pub fn write(self: *Surface, bytes: []const u8) void {
        if (self.closed or bytes.len == 0) return;
        g.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
        self.queueDraw();
    }

    pub fn scroll(self: *Surface, delta: isize) void {
        _ = g.ghostty_terminal_scroll_viewport(self.terminal, g.scrollDelta(delta));
        self.queueDraw();
    }

    pub fn scrollBottom(self: *Surface) void {
        _ = g.ghostty_terminal_scroll_viewport(self.terminal, .{ .tag = .bottom, .value = .{ .delta = 0 } });
        self.queueDraw();
    }

    /// Paste text through the ghostty paste path (bracketed paste per mode 2004,
    /// unsafe-paste rejection). Returns false when the paste was rejected/empty.
    pub fn paste(self: *Surface, text: []const u8) bool {
        if (self.closed or text.len == 0) return false;
        self.paste_bytes = text;
        self.paste_written = false;
        const mime = g.String{ .ptr = "text/plain;charset=utf-8", .len = 24 };
        var p: g.Paste = undefined;
        g.sizedInit(&p);
        p.location = .standard;
        p.source = .clipboard;
        p.mimes = @ptrCast(&mime);
        p.mimes_len = 1;
        p.reader = .{ .read = &pasteReader, .userdata = self };
        p.allow_unsafe = false;
        var pasted = false;
        const result = g.ghostty_terminal_paste(self.terminal, &p, &pasted);
        self.paste_bytes = &.{};
        return g.ok(result) and pasted;
    }

    fn pasteReader(userdata: ?*anyopaque, mime: g.String, writer: g.Writer) callconv(.c) bool {
        _ = mime;
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.paste_bytes.len == 0) return true;
        const write_fn = writer.write orelse return false;
        return write_fn(writer.userdata, self.paste_bytes.ptr, self.paste_bytes.len);
    }

    /// Copy the current selection to the system clipboard as plain text. This is
    /// a user action, distinct from the denied OSC clipboard effects.
    pub fn copySelection(self: *Surface) bool {
        var selection: g.Selection = undefined;
        if (!g.ok(g.ghostty_terminal_get(self.terminal, .selection, &selection))) return false;
        var formatter: ?*g.Formatter = null;
        if (!g.ok(g.ghostty_formatter_terminal_new(null, &formatter, self.terminal))) return false;
        defer g.ghostty_formatter_free(formatter);
        const emit: g.FormatterFormat = .plain;
        _ = g.ghostty_formatter_set(formatter, .emit, &emit);
        const trim = false;
        _ = g.ghostty_formatter_set(formatter, .trim, &trim);
        _ = g.ghostty_formatter_set(formatter, .selection, &selection);
        var needed: usize = 0;
        if (g.ghostty_formatter_format_buf(formatter, null, 0, &needed) != g.OUT_OF_SPACE or needed == 0) return false;
        const buf = u.a.alloc(u8, needed) catch return false;
        defer u.a.free(buf);
        var written: usize = 0;
        if (!g.ok(g.ghostty_formatter_format_buf(formatter, buf.ptr, needed, &written))) return false;
        const display = c.gtk_widget_get_display(self.widget) orelse return false;
        const clipboard = c.gdk_display_get_clipboard(display) orelse return false;
        const z = u.a.dupeSentinel(u8, buf[0..written], 0) catch return false;
        defer u.a.free(z);
        c.gdk_clipboard_set_text(clipboard, z);
        return true;
    }

    pub fn selectAll(self: *Surface) void {
        var selection: g.Selection = undefined;
        if (g.ok(g.ghostty_terminal_select_all(self.terminal, &selection))) {
            _ = g.ghostty_terminal_set(self.terminal, .selection, &selection);
            self.queueDraw();
        }
    }

    pub fn clearSelection(self: *Surface) void {
        _ = g.ghostty_terminal_set(self.terminal, .selection, null);
        self.queueDraw();
    }

    /// Resize to a pixel allocation; mirrors the grid onto the PTY.
    pub fn resizeToPixels(self: *Surface, width: c_int, height: c_int) void {
        if (self.closed or width <= 0 or height <= 0) return;
        const cols = @max(1, @as(u16, @intCast(@min(65535, @divTrunc(width, @as(c_int, @intCast(self.cell_width)))))));
        const rows = @max(1, @as(u16, @intCast(@min(65535, @divTrunc(height, @as(c_int, @intCast(self.cell_height)))))));
        self.resizeGrid(cols, rows);
    }

    pub fn resizeGrid(self: *Surface, cols: u16, rows: u16) void {
        if (self.closed) return;
        if (cols == self.cols and rows == self.rows_count) {
            // Still refresh pixel dimensions for size reports/image protocols.
            _ = g.ghostty_terminal_resize(self.terminal, cols, rows, self.cell_width, self.cell_height);
            return;
        }
        if (!g.ok(g.ghostty_terminal_resize(self.terminal, cols, rows, self.cell_width, self.cell_height))) return;
        self.cols = cols;
        self.rows_count = rows;
        _ = g.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.terminal);
        _ = g.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.terminal);
        self.hooks.resize_pty(self.hooks.context, cols, rows);
        self.queueDraw();
    }

    pub fn deinit(self: *Surface) void {
        if (self.closed) return;
        self.closed = true;
        // Invalidate any in-flight paste before freeing the Surface: the
        // callback may still fire (cancelled) on the main thread afterwards.
        if (self.paste_cancel) |cancel| {
            if (c.g_object_get_data(@ptrCast(cancel), "coral-paste")) |p| {
                const ctx: *PasteCtx = @ptrCast(@alignCast(p));
                ctx.cancelled = true;
            }
            c.g_cancellable_cancel(cancel);
            c.g_object_unref(@ptrCast(cancel));
            self.paste_cancel = null;
        }
        if (self.tick_id != 0) c.gtk_widget_remove_tick_callback(self.widget, self.tick_id);
        self.tick_id = 0;
        for (self.controllers[0..self.controller_count]) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_widget_remove_controller(self.widget, controller);
        }
        self.controller_count = 0;
        g.ghostty_mouse_event_free(self.mouse_event);
        g.ghostty_mouse_encoder_free(self.mouse_encoder);
        g.ghostty_key_event_free(self.key_event);
        g.ghostty_key_encoder_free(self.key_encoder);
        g.ghostty_render_state_row_cells_free(self.cells);
        g.ghostty_render_state_row_iterator_free(self.rows);
        g.ghostty_render_state_free(self.render);
        g.ghostty_terminal_free(self.terminal);
        c.pango_font_description_free(self.font);
        c.pango_font_description_free(self.font_bold);
        c.pango_font_description_free(self.font_italic);
        c.pango_font_description_free(self.font_bold_italic);
        c.g_object_unref(self.widget);
    }

    // ---- ghostty effect callbacks (synchronous, during vt_write) ----
    fn onWritePty(_: ?*g.Terminal, userdata: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        self.hooks.write_pty(self.hooks.context, data[0..len]);
    }
    fn onTitleChanged(_: ?*g.Terminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        const hook = self.hooks.title_changed orelse return;
        var title: g.String = undefined;
        if (g.ok(g.ghostty_terminal_get(self.terminal, .title, &title))) hook(self.hooks.context, title.ptr[0..title.len]);
    }
    fn onPwdChanged(_: ?*g.Terminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        const hook = self.hooks.pwd_changed orelse return;
        var pwd: g.String = undefined;
        if (g.ok(g.ghostty_terminal_get(self.terminal, .pwd, &pwd))) hook(self.hooks.context, pwd.ptr[0..pwd.len]);
    }
    fn onBell(_: ?*g.Terminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        if (self.hooks.bell) |bell| bell(self.hooks.context);
    }
    fn onClipboardWrite(_: ?*g.Terminal, _: ?*anyopaque, request: *const g.ClipboardWrite) callconv(.c) void {
        var reply: g.ClipboardWriteReply = undefined;
        g.sizedInit(&reply);
        reply.result = .denied;
        reply.remember = false;
        if (request.reply) |reply_fn| reply_fn(request, &reply);
    }
    fn onClipboardRead(_: ?*g.Terminal, _: ?*anyopaque, read: *const g.ClipboardRead) callconv(.c) void {
        var reply: g.ClipboardReadReply = undefined;
        g.sizedInit(&reply);
        reply.result = .denied;
        reply.contents = null;
        reply.contents_len = 0;
        reply.available = null;
        reply.available_len = 0;
        reply.remember = false;
        if (read.reply) |reply_fn| reply_fn(read, &reply);
    }

    // ---- Rendering ----
    fn draw(area: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, userdata: ?*anyopaque) callconv(.c) void {
        _ = area;
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        self.renderFrame(cr.?, width, height);
    }

    fn renderFrame(self: *Surface, cr: *c.cairo_t, width: c_int, height: c_int) void {
        if (!g.ok(g.ghostty_render_state_update(self.render, self.terminal))) return;
        defer _ = g.ghostty_render_state_clean(self.render);
        var colors: g.RenderColors = undefined;
        g.sizedInit(&colors);
        if (!g.ok(g.ghostty_render_state_get(self.render, .colors, &colors))) return;
        var cursor: g.RenderCursor = undefined;
        g.sizedInit(&cursor);
        _ = g.ghostty_render_state_get(self.render, .cursor, &cursor);
        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = g.ghostty_render_state_get(self.render, .cols, &cols);
        _ = g.ghostty_render_state_get(self.render, .rows, &rows);
        const cw: f64 = @floatFromInt(self.cell_width);
        const ch: f64 = @floatFromInt(self.cell_height);

        // Default background fills the whole allocation (including padding).
        setColor(cr, colors.background, 1.0);
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(width), @floatFromInt(height));
        c.cairo_fill(cr);

        const layout = c.pango_cairo_create_layout(cr).?;
        defer c.g_object_unref(layout);

        const cursor_block = cursor.visible and cursor.viewport_has_value and cursor.visual_style == .block;
        var y: u16 = 0;
        if (g.ok(g.ghostty_render_state_get(self.render, .row_iterator, self.rows))) {
            while (g.ghostty_render_state_row_iterator_next(self.rows)) : (y += 1) {
                if (y >= rows) break;
                if (!g.ok(g.ghostty_render_state_row_get(self.rows, .cells, self.cells))) continue;
                var x: u16 = 0;
                while (g.ghostty_render_state_row_cells_next(self.cells)) : (x += 1) {
                    if (x >= cols) break;
                    self.drawCell(cr, layout, &colors, &cursor, cursor_block, x, y, cw, ch);
                }
            }
        }
        self.drawCursor(cr, &colors, &cursor, cw, ch);
    }

    fn drawCell(self: *Surface, cr: *c.cairo_t, layout: *c.PangoLayout, colors: *const g.RenderColors, cursor: *const g.RenderCursor, cursor_block: bool, x: u16, y: u16, cw: f64, ch: f64) void {
        var style: g.Style = undefined;
        _ = g.ghostty_render_state_row_cells_get(self.cells, .style, &style);
        var bg: g.ColorRgb = colors.background;
        var bg_buf: g.ColorRgb = undefined;
        if (g.ok(g.ghostty_render_state_row_cells_get(self.cells, .bg_color, &bg_buf))) bg = bg_buf;
        var fg: g.ColorRgb = colors.foreground;
        var fg_buf: g.ColorRgb = undefined;
        if (g.ok(g.ghostty_render_state_row_cells_get(self.cells, .fg_color, &fg_buf))) fg = fg_buf;
        var selected = false;
        _ = g.ghostty_render_state_row_cells_get(self.cells, .selected, &selected);

        const at_cursor = cursor_block and cursor.viewport_x == x and cursor.viewport_y == y;
        if (style.flags & g.STYLE_INVERSE != 0 or selected) {
            const tmp = fg;
            fg = bg;
            bg = tmp;
        }
        if (at_cursor) {
            bg = if (colors.cursor_has_value) colors.cursor else colors.foreground;
            fg = colors.background;
        }
        const px: f64 = @as(f64, @floatFromInt(x)) * cw;
        const py: f64 = @as(f64, @floatFromInt(y)) * ch;
        if (bg.r != colors.background.r or bg.g != colors.background.g or bg.b != colors.background.b) {
            setColor(cr, bg, 1.0);
            c.cairo_rectangle(cr, px, py, cw, ch);
            c.cairo_fill(cr);
        }
        var text_buf: [64]u8 = undefined;
        var buf = g.Buffer{ .ptr = &text_buf, .cap = text_buf.len, .len = 0 };
        const gr = g.ghostty_render_state_row_cells_get(self.cells, .graphemes_utf8, &buf);
        if (g.ok(gr) and buf.len > 0 and style.flags & g.STYLE_INVISIBLE == 0) {
            const font = pickFont(self, style);
            c.pango_layout_set_font_description(layout, font);
            c.pango_layout_set_text(layout, @ptrCast(text_buf[0..buf.len].ptr), @intCast(buf.len));
            const alpha: f64 = if (style.flags & g.STYLE_FAINT != 0) 0.5 else 1.0;
            setColor(cr, fg, alpha);
            c.cairo_move_to(cr, px, py);
            c.pango_cairo_show_layout(cr, layout);
        }
        if (g.underline(style) != 0) {
            setColor(cr, if (style.underline_color.tag == .rgb) style.underline_color.value.rgb else fg, 1.0);
            c.cairo_rectangle(cr, px, py + ch - 1.5, cw, 1.0);
            c.cairo_fill(cr);
        }
        if (style.flags & g.STYLE_STRIKETHROUGH != 0) {
            setColor(cr, fg, 1.0);
            c.cairo_rectangle(cr, px, py + ch * 0.55, cw, 1.0);
            c.cairo_fill(cr);
        }
        if (style.flags & g.STYLE_OVERLINE != 0) {
            setColor(cr, fg, 1.0);
            c.cairo_rectangle(cr, px, py, cw, 1.0);
            c.cairo_fill(cr);
        }
    }

    fn drawCursor(self: *Surface, cr: *c.cairo_t, colors: *const g.RenderColors, cursor: *const g.RenderCursor, cw: f64, ch: f64) void {
        _ = self;
        if (!cursor.visible or !cursor.viewport_has_value) return;
        if (cursor.visual_style == .block) return; // drawn inline as inverse cell
        const px: f64 = @as(f64, @floatFromInt(cursor.viewport_x)) * cw;
        const py: f64 = @as(f64, @floatFromInt(cursor.viewport_y)) * ch;
        const color = if (colors.cursor_has_value) colors.cursor else colors.foreground;
        setColor(cr, color, 1.0);
        switch (cursor.visual_style) {
            .bar => c.cairo_rectangle(cr, px, py, 2.0, ch),
            .underline => c.cairo_rectangle(cr, px, py + ch - 2.0, cw, 2.0),
            .block_hollow => {
                c.cairo_rectangle(cr, px + 0.5, py + 0.5, cw - 1.0, ch - 1.0);
                c.cairo_set_line_width(cr, 1.0);
                c.cairo_stroke(cr);
                return;
            },
            .block => return,
        }
        c.cairo_fill(cr);
    }

    fn pickFont(self: *Surface, style: g.Style) *c.PangoFontDescription {
        const bold = style.flags & g.STYLE_BOLD != 0;
        const italic = style.flags & g.STYLE_ITALIC != 0;
        if (bold and italic) return self.font_bold_italic;
        if (bold) return self.font_bold;
        if (italic) return self.font_italic;
        return self.font;
    }

    fn setColor(cr: *c.cairo_t, color: g.ColorRgb, alpha: f64) void {
        c.cairo_set_source_rgba(cr, @as(f64, @floatFromInt(color.r)) / 255.0, @as(f64, @floatFromInt(color.g)) / 255.0, @as(f64, @floatFromInt(color.b)) / 255.0, alpha);
    }

    // ---- Resize / redraw tick ----
    fn tick(widget: [*c]c.GtkWidget, _: ?*c.GdkFrameClock, userdata: ?*anyopaque) callconv(.c) c_int {
        _ = widget;
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return 0;
        const width = c.gtk_widget_get_width(self.widget);
        const height = c.gtk_widget_get_height(self.widget);
        // Resize only when the allocation changes, so an explicit grid resize
        // persists until the next real window allocation.
        if (width == self.last_alloc_width and height == self.last_alloc_height) return 1;
        self.last_alloc_width = width;
        self.last_alloc_height = height;
        if (width > 0 and height > 0) {
            const cols = @max(1, @as(u16, @intCast(@min(65535, @divTrunc(width, @as(c_int, @intCast(self.cell_width)))))));
            const rows = @max(1, @as(u16, @intCast(@min(65535, @divTrunc(height, @as(c_int, @intCast(self.cell_height)))))));
            if (cols != self.cols or rows != self.rows_count) self.resizeGrid(cols, rows);
        }
        return 1;
    }

    // ---- Keyboard ----
    fn keyPressed(_: *c.GtkEventController, keyval: c_uint, keycode: c_uint, state: c_uint, userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return 0;
        // Ctrl+Shift+C / Ctrl+Shift+V are workbench copy/paste, not PTY input.
        const mods = translateMods(state);
        if (mods & g.MODS_CTRL != 0 and mods & g.MODS_SHIFT != 0) {
            if (keyval == c.GDK_KEY_c or keyval == c.GDK_KEY_C) {
                _ = self.copySelection();
                return 1;
            }
            if (keyval == c.GDK_KEY_v or keyval == c.GDK_KEY_V) {
                self.requestPaste();
                return 1;
            }
        }
        self.encodeKey(keyval, keycode, state, .press);
        return 1;
    }

    fn keyReleased(controller: *c.GtkEventController, keyval: c_uint, keycode: c_uint, state: c_uint, userdata: ?*anyopaque) callconv(.c) c_int {
        _ = controller;
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return 0;
        self.encodeKey(keyval, keycode, state, .release);
        return 1;
    }

    fn encodeKey(self: *Surface, keyval: c_uint, keycode: c_uint, state: c_uint, action: g.KeyAction) void {
        const key = mapKeycode(keycode) orelse mapKeyval(keyval) orelse .unidentified;
        const mods = translateMods(state);
        _ = g.ghostty_key_event_set_action(self.key_event, action);
        _ = g.ghostty_key_event_set_key(self.key_event, key);
        _ = g.ghostty_key_event_set_mods(self.key_event, mods);
        const consumed = translateMods(c.gdk_key_event_get_consumed_modifiers(c.gtk_event_controller_get_current_event(self.controllers[0])));
        _ = g.ghostty_key_event_set_consumed_mods(self.key_event, consumed);
        // Layout text for printable keys; the encoder derives Ctrl/Alt sequences
        // from the logical key + mods, so omit text for transformed/control keys.
        var text_buf: [8]u8 = undefined;
        var text_len: usize = 0;
        const unicode = c.gdk_keyval_to_unicode(keyval);
        if (unicode >= 0x20 and unicode != 0x7f and mods & (g.MODS_CTRL | g.MODS_ALT) == 0) {
            text_len = std.unicode.utf8Encode(@intCast(unicode), &text_buf) catch 0;
        }
        _ = g.ghostty_key_event_set_utf8(self.key_event, .{ .ptr = &text_buf, .len = text_len });
        var out: [128]u8 = undefined;
        var written: usize = 0;
        const result = g.ghostty_key_encoder_encode(self.key_encoder, self.key_event, &out, out.len, &written);
        if (g.ok(result) and written > 0) {
            self.hooks.write_pty(self.hooks.context, out[0..written]);
            self.scrollBottom();
        } else if (result == g.OUT_OF_SPACE and written <= 4096) {
            const big = u.a.alloc(u8, written) catch return;
            defer u.a.free(big);
            var n: usize = 0;
            if (g.ok(g.ghostty_key_encoder_encode(self.key_encoder, self.key_event, big.ptr, big.len, &n)) and n > 0) {
                self.hooks.write_pty(self.hooks.context, big[0..n]);
                self.scrollBottom();
            }
        }
    }

    fn requestPaste(self: *Surface) void {
        if (self.closed or self.paste_pending) return;
        const cancel = self.paste_cancel orelse return;
        if (c.g_cancellable_is_cancelled(cancel) != 0) return;
        const display = c.gtk_widget_get_display(self.widget) orelse return;
        const clipboard = c.gdk_display_get_clipboard(display) orelse return;
        const ctx = a.create(PasteCtx) catch return;
        ctx.* = .{ .surface = self, .cancel = cancel, .cancelled = false };
        // The ctx lives on the cancellable; the callback holds its own ref so
        // the ctx stays valid until pasteReady runs, even if the Surface dies.
        c.g_object_set_data_full(@ptrCast(cancel), "coral-paste", ctx, &freePasteCtx);
        _ = c.g_object_ref(@ptrCast(cancel));
        self.paste_pending = true;
        c.gdk_clipboard_read_text_async(clipboard, cancel, &pasteReady, ctx);
    }
    fn pasteReady(source: [*c]c.GObject, res: ?*c.GAsyncResult, userdata: ?*anyopaque) callconv(.c) void {
        const ctx: *PasteCtx = @ptrCast(@alignCast(userdata.?));
        const cancel = ctx.cancel;
        const text = c.gdk_clipboard_read_text_finish(u.cast(c.GdkClipboard, source), res, null);
        // ctx.cancelled is set by Surface.deinit before the Surface is freed;
        // when set, never touch ctx.surface. ctx itself is kept alive by the
        // callback's cancellable ref until the unref below.
        if (!ctx.cancelled) {
            ctx.surface.paste_pending = false;
            if (text != null) _ = ctx.surface.paste(std.mem.span(text));
        }
        if (text != null) c.g_free(text);
        c.g_object_unref(@ptrCast(cancel)); // may finalize the cancellable + ctx
    }

    // ---- Mouse ----
    fn mouseTracking(self: *Surface) bool {
        var mode: c_int = 0;
        _ = g.ghostty_terminal_get(self.terminal, .mouse_tracking, &mode);
        return mode != 0;
    }

    fn mousePressed(controller: *c.GtkEventController, n_press: c_int, x: f64, y: f64, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        self.focus();
        const button = c.gtk_gesture_single_get_current_button(u.cast(c.GtkGestureSingle, controller));
        const state = c.gtk_event_controller_get_current_event_state(controller);
        if (self.mouseTracking()) {
            self.encodeMouse(.press, button, x, y, state);
            return;
        }
        if (button == 1) {
            if (n_press == 2) {
                self.selectWordAt(x, y);
            } else if (n_press >= 3) {
                self.selectLineAt(x, y);
            } else {
                self.clearSelection();
                self.select_anchor = self.refAt(x, y);
                self.selecting = true;
                self.dragged = false;
            }
        } else if (button == 2) {
            // Middle click pastes the primary selection in classic terminals;
            // here it pastes the clipboard through the safe paste path.
            self.requestPaste();
        }
    }

    fn mouseReleased(controller: *c.GtkEventController, n_press: c_int, x: f64, y: f64, userdata: ?*anyopaque) callconv(.c) void {
        _ = n_press;
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        const button = c.gtk_gesture_single_get_current_button(u.cast(c.GtkGestureSingle, controller));
        const state = c.gtk_event_controller_get_current_event_state(controller);
        if (self.mouseTracking()) self.encodeMouse(.release, button, x, y, state);
        self.selecting = false;
    }

    fn dragBegin(controller: *c.GtkGestureDrag, x: f64, y: f64, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        if (self.mouseTracking()) {
            self.encodeMouse(.press, 1, x, y, c.gtk_event_controller_get_current_event_state(u.cast(c.GtkEventController, controller)));
        }
    }

    fn dragUpdate(controller: *c.GtkGestureDrag, offset_x: f64, offset_y: f64, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        var sx: f64 = 0;
        var sy: f64 = 0;
        _ = c.gtk_gesture_drag_get_start_point(controller, &sx, &sy);
        const x = sx + offset_x;
        const y = sy + offset_y;
        if (self.mouseTracking()) {
            self.encodeMouse(.motion, 1, x, y, c.gtk_event_controller_get_current_event_state(u.cast(c.GtkEventController, controller)));
            return;
        }
        if (!self.selecting) {
            self.select_anchor = self.refAt(sx, sy);
            self.selecting = true;
        }
        self.dragged = true;
        const end = self.refAt(x, y);
        var selection = g.Selection{ .start = self.select_anchor, .end = end, .rectangle = false };
        _ = g.ghostty_terminal_set(self.terminal, .selection, &selection);
        self.queueDraw();
    }

    fn dragEnd(controller: *c.GtkGestureDrag, offset_x: f64, offset_y: f64, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return;
        var sx: f64 = 0;
        var sy: f64 = 0;
        _ = c.gtk_gesture_drag_get_start_point(controller, &sx, &sy);
        if (self.mouseTracking()) {
            self.encodeMouse(.release, 1, sx + offset_x, sy + offset_y, c.gtk_event_controller_get_current_event_state(u.cast(c.GtkEventController, controller)));
        }
        self.selecting = false;
    }

    fn scrolled(controller: *c.GtkEventControllerScroll, _: f64, dy: f64, userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(userdata.?));
        if (self.closed) return 0;
        if (self.mouseTracking()) {
            const state = c.gtk_event_controller_get_current_event_state(u.cast(c.GtkEventController, controller));
            const button: c_uint = if (dy < 0) 4 else 5;
            var x: f64 = 0;
            var y: f64 = 0;
            if (c.gtk_event_controller_get_current_event(u.cast(c.GtkEventController, controller))) |event| {
                _ = c.gdk_event_get_position(event, &x, &y);
            }
            self.encodeMouse(.press, button, x, y, state);
            self.encodeMouse(.release, button, x, y, state);
            return 1;
        }
        const lines: isize = if (dy < 0) -3 else 3;
        self.scroll(lines);
        return 1;
    }

    fn encodeMouse(self: *Surface, action: g.MouseAction, button: c_uint, x: f64, y: f64, state: c_uint) void {
        var size: g.MouseEncoderSize = undefined;
        g.sizedInit(&size);
        size.screen_width = @intCast(@max(1, c.gtk_widget_get_width(self.widget)));
        size.screen_height = @intCast(@max(1, c.gtk_widget_get_height(self.widget)));
        size.cell_width = self.cell_width;
        size.cell_height = self.cell_height;
        _ = g.ghostty_mouse_encoder_set(self.mouse_encoder, .size, &size);
        _ = g.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.terminal);
        _ = g.ghostty_mouse_event_set_action(self.mouse_event, action);
        const mapped: g.MouseButton = switch (button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            4 => .four,
            5 => .five,
            else => .unknown,
        };
        if (mapped == .unknown) {
            _ = g.ghostty_mouse_event_clear_button(self.mouse_event);
        } else {
            _ = g.ghostty_mouse_event_set_button(self.mouse_event, mapped);
        }
        _ = g.ghostty_mouse_event_set_mods(self.mouse_event, translateMods(state));
        _ = g.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = x, .y = y });
        var out: [128]u8 = undefined;
        var written: usize = 0;
        if (g.ok(g.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, &out, out.len, &written)) and written > 0) {
            self.hooks.write_pty(self.hooks.context, out[0..written]);
        }
    }

    fn cellAt(self: *Surface, x: f64, y: f64) struct { x: u16, y: u32 } {
        const col = @max(0, @as(i32, @intFromFloat(@floor(x / @as(f64, @floatFromInt(self.cell_width))))));
        const row = @max(0, @as(i32, @intFromFloat(@floor(y / @as(f64, @floatFromInt(self.cell_height))))));
        return .{
            .x = @intCast(@min(col, @as(i32, self.cols) - 1)),
            .y = @intCast(@min(row, @as(i32, self.rows_count) - 1)),
        };
    }

    fn refAt(self: *Surface, x: f64, y: f64) g.GridRef {
        const cell = self.cellAt(x, y);
        var ref: g.GridRef = .{ .node = null, .x = 0, .y = 0 };
        _ = g.ghostty_terminal_grid_ref(self.terminal, g.viewportPoint(cell.x, cell.y), &ref);
        return ref;
    }

    fn selectWordAt(self: *Surface, x: f64, y: f64) void {
        var opts: g.SelectWordOptions = undefined;
        g.sizedInit(&opts);
        opts.ref = self.refAt(x, y);
        opts.boundary_codepoints = null;
        opts.boundary_codepoints_len = 0;
        var selection: g.Selection = undefined;
        if (g.ok(g.ghostty_terminal_select_word(self.terminal, &opts, &selection))) {
            _ = g.ghostty_terminal_set(self.terminal, .selection, &selection);
            self.queueDraw();
        }
    }

    fn selectLineAt(self: *Surface, x: f64, y: f64) void {
        var opts: g.SelectLineOptions = undefined;
        g.sizedInit(&opts);
        opts.ref = self.refAt(x, y);
        opts.whitespace = null;
        opts.whitespace_len = 0;
        opts.semantic_prompt_boundary = false;
        var selection: g.Selection = undefined;
        if (g.ok(g.ghostty_terminal_select_line(self.terminal, &opts, &selection))) {
            _ = g.ghostty_terminal_set(self.terminal, .selection, &selection);
            self.queueDraw();
        }
    }
};

fn translateMods(state: c_uint) u16 {
    var mods: u16 = 0;
    if (state & c.GDK_SHIFT_MASK != 0) mods |= g.MODS_SHIFT;
    if (state & c.GDK_CONTROL_MASK != 0) mods |= g.MODS_CTRL;
    if (state & c.GDK_ALT_MASK != 0) mods |= g.MODS_ALT;
    if (state & c.GDK_SUPER_MASK != 0) mods |= g.MODS_SUPER;
    if (state & c.GDK_LOCK_MASK != 0) mods |= g.MODS_CAPS_LOCK;
    if (state & 0x10 != 0) mods |= g.MODS_NUM_LOCK; // GDK_MOD2_MASK
    return mods;
}

/// Physical (layout-independent) key from the Linux evdev keycode GTK reports.
fn mapKeycode(code: c_uint) ?g.Key {
    return switch (code) {
        1 => .escape,
        2 => .digit_1,
        3 => .digit_2,
        4 => .digit_3,
        5 => .digit_4,
        6 => .digit_5,
        7 => .digit_6,
        8 => .digit_7,
        9 => .digit_8,
        10 => .digit_9,
        11 => .digit_0,
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .bracket_left,
        27 => .bracket_right,
        28 => .enter,
        29 => .control_left,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .quote,
        41 => .backquote,
        42 => .shift_left,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .shift_right,
        55 => .numpad_multiply,
        56 => .alt_left,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .numpad_7,
        72 => .numpad_8,
        73 => .numpad_9,
        74 => .numpad_subtract,
        75 => .numpad_4,
        76 => .numpad_5,
        77 => .numpad_6,
        78 => .numpad_add,
        79 => .numpad_1,
        80 => .numpad_2,
        81 => .numpad_3,
        82 => .numpad_0,
        83 => .numpad_decimal,
        87 => .f11,
        88 => .f12,
        96 => .numpad_enter,
        97 => .control_right,
        98 => .numpad_divide,
        99 => .print_screen,
        100 => .alt_right,
        102 => .home,
        103 => .arrow_up,
        104 => .page_up,
        105 => .arrow_left,
        106 => .arrow_right,
        107 => .end,
        108 => .arrow_down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125 => .meta_left,
        126 => .meta_right,
        127 => .context_menu,
        else => null,
    };
}

/// Fallback for keyvals without a known evdev keycode (e.g. virtual keyboards).
fn mapKeyval(keyval: c_uint) ?g.Key {
    if (keyval >= 'a' and keyval <= 'z') return @fromBackingInt(@intCast(@as(c_int, @intCast(keyval - 'a')) + @backingInt(g.Key.a)));
    if (keyval >= 'A' and keyval <= 'Z') return @fromBackingInt(@intCast(@as(c_int, @intCast(keyval - 'A')) + @backingInt(g.Key.a)));
    if (keyval >= '0' and keyval <= '9') return @fromBackingInt(@intCast(@as(c_int, @intCast(keyval - '0')) + @backingInt(g.Key.digit_0)));
    return switch (keyval) {
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => .enter,
        c.GDK_KEY_BackSpace => .backspace,
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => .tab,
        c.GDK_KEY_Escape => .escape,
        c.GDK_KEY_space => .space,
        c.GDK_KEY_Delete, c.GDK_KEY_KP_Delete => .delete,
        c.GDK_KEY_Home, c.GDK_KEY_KP_Home => .home,
        c.GDK_KEY_End, c.GDK_KEY_KP_End => .end,
        c.GDK_KEY_Page_Up, c.GDK_KEY_KP_Page_Up => .page_up,
        c.GDK_KEY_Page_Down, c.GDK_KEY_KP_Page_Down => .page_down,
        c.GDK_KEY_Insert, c.GDK_KEY_KP_Insert => .insert,
        c.GDK_KEY_Left, c.GDK_KEY_KP_Left => .arrow_left,
        c.GDK_KEY_Right, c.GDK_KEY_KP_Right => .arrow_right,
        c.GDK_KEY_Up, c.GDK_KEY_KP_Up => .arrow_up,
        c.GDK_KEY_Down, c.GDK_KEY_KP_Down => .arrow_down,
        c.GDK_KEY_F1 => .f1,
        c.GDK_KEY_F2 => .f2,
        c.GDK_KEY_F3 => .f3,
        c.GDK_KEY_F4 => .f4,
        c.GDK_KEY_F5 => .f5,
        c.GDK_KEY_F6 => .f6,
        c.GDK_KEY_F7 => .f7,
        c.GDK_KEY_F8 => .f8,
        c.GDK_KEY_F9 => .f9,
        c.GDK_KEY_F10 => .f10,
        c.GDK_KEY_F11 => .f11,
        c.GDK_KEY_F12 => .f12,
        else => null,
    };
}

// ---- Integration tests (display-backed; skipped when no compositor) ----
const TestCtx = struct {
    written: std.ArrayList(u8) = .empty,
    resizes: usize = 0,
    last_cols: u16 = 0,
    last_rows: u16 = 0,
    titles: usize = 0,
    fn writePty(ctx: *anyopaque, bytes: []const u8) void {
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        self.written.appendSlice(a, bytes) catch unreachable;
    }
    fn resizePty(ctx: *anyopaque, cols: u16, rows: u16) void {
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn titleChanged(ctx: *anyopaque, _: []const u8) void {
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        self.titles += 1;
    }
    fn hooks(self: *TestCtx) Hooks {
        return .{ .context = self, .write_pty = &writePty, .resize_pty = &resizePty, .title_changed = &titleChanged };
    }
    fn deinit(self: *TestCtx) void {
        self.written.deinit(a);
    }
};

fn plainText(surface: *Surface) []const u8 {
    var formatter: ?*g.Formatter = null;
    if (!g.ok(g.ghostty_formatter_terminal_new(null, &formatter, surface.terminal))) return "";
    defer g.ghostty_formatter_free(formatter);
    const emit: g.FormatterFormat = .plain;
    _ = g.ghostty_formatter_set(formatter, .emit, &emit);
    var needed: usize = 0;
    if (g.ghostty_formatter_format_buf(formatter, null, 0, &needed) != g.OUT_OF_SPACE or needed == 0) return "";
    const buf = a.alloc(u8, needed) catch return "";
    var written: usize = 0;
    if (!g.ok(g.ghostty_formatter_format_buf(formatter, buf.ptr, needed, &written))) {
        a.free(buf);
        return "";
    }
    return buf[0..written];
}

fn drainMain() void {
    for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
}

test "surface renders VT state, resizes, pastes and denies OSC clipboard" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    var ctx: TestCtx = .{};
    defer ctx.deinit();
    var surface = try Surface.init(ctx.hooks(), 80, 24);
    defer surface.deinit();
    surface.attach();

    // Output rendering: plain text, ANSI color, split UTF-8 / wide graphemes.
    surface.write("hello \x1b[1;32mGREEN\x1b[0m world\r\n");
    surface.write("Unicode: h\xc3\xa9\xce\xbb \xe4\xb8\xad\xe6\x96\x87 \xf0\x9f\x99\x82\r\n");
    const text = plainText(&surface);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GREEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\xe4\xb8\xad\xe6\x96\x87") != null);

    // Title metadata updates a label counter, never an action.
    surface.write("\x1b]2;Coral Title\x07");
    try std.testing.expect(ctx.titles >= 1);

    // Resize mirrors the grid onto the PTY hook.
    surface.resizeGrid(40, 10);
    try std.testing.expectEqual(@as(u16, 40), surface.cols);
    try std.testing.expectEqual(@as(u16, 10), surface.rows_count);
    try std.testing.expect(ctx.resizes >= 1);
    try std.testing.expectEqual(@as(u16, 40), ctx.last_cols);

    // Scrollback viewport moves without crashing.
    surface.write("line1\r\nline2\r\nline3\r\n");
    surface.scroll(-2);
    surface.scrollBottom();

    // Safe paste flows through the write_pty hook.
    ctx.written.clearRetainingCapacity();
    try std.testing.expect(surface.paste("pasted"));
    try std.testing.expect(std.mem.indexOf(u8, ctx.written.items, "pasted") != null);

    // OSC 52 clipboard write is denied: no clipboard effect, no crash.
    surface.write("\x1b]52;c;Y29yYWw=\x07");
    // OSC 52 read is denied: the terminal answers with an empty clipboard.
    ctx.written.clearRetainingCapacity();
    surface.write("\x1b]52;c;?\x07");
    drainMain();

    // Selection + copy path exercises the formatter.
    surface.selectAll();
    _ = surface.copySelection();
    surface.clearSelection();
}

test "surface round-trips a real PTY under the worker/GIO model" {
    if (c.gtk_init_check() == 0) return error.SkipZigTest;
    const pty = @import("pty.zig");
    var ctx: TestCtx = .{};
    defer ctx.deinit();
    var surface = try Surface.init(ctx.hooks(), 80, 24);
    defer surface.deinit();
    surface.attach();

    const argv = [_:null]?[*:0]const u8{"/bin/sh"};
    const env = [_:null]?[*:0]const u8{ "LANG=C.UTF-8", "TERM=xterm-256color", "PATH=/usr/bin:/bin" };
    var handle = try pty.start(.{ .authorization = .approved, .argv = &argv, .environment = &env, .cwd = "/" });
    defer handle.deinit();

    // The test drains the master directly (the controller uses a GIO watch).
    const shell_input = "echo CORAL_PTY_OK\nexit 7\n";
    _ = try handle.write(shell_input);
    var buf: [4096]u8 = undefined;
    const deadline = pty.os.nowMs() + 5000;
    var found = false;
    while (pty.os.nowMs() < deadline) {
        const n = handle.read(&buf) catch |err| switch (err) {
            error.WouldBlock => {
                drainMain();
                _ = pty.os.poll(&.{}, 0, 5);
                continue;
            },
            else => break,
        };
        if (n == 0) break;
        surface.write(buf[0..n]);
        const text = plainText(&surface);
        defer a.free(text);
        if (std.mem.indexOf(u8, text, "CORAL_PTY_OK") != null) found = true;
        if (found) break;
    }
    try std.testing.expect(found);
    handle.cancel();
    const report = handle.wait();
    try std.testing.expectEqual(@as(c_int, 0), report.spawn_errno);
    try std.testing.expectEqual(@as(c_int, 1), report.reaped);
    try std.testing.expectEqual(@as(c_int, 7 << 8), report.status);
}
