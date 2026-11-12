//! Narrow C ABI bindings for the private libghostty-vt (VT state/render-state
//! only). Signatures checked against ghostty/vt.h 1.0.1. No C bridge, no VTE.
//! libghostty-vt parses VT and keeps screen/scrollback/cursor/styles; it never
//! draws and never talks to a PTY. Drawing, input routing and the PTY belong to
//! surface.zig / terminal_controller.zig. All handles are opaque pointers; all
//! C enums are backed by c_int (GHOSTTY_ENUM_TYPED). Sized structs must be
//! initialized with sizedInit() before a _get() call.
const std = @import("std");

// ---- Opaque handles ----
pub const Terminal = opaque {};
pub const RenderState = opaque {};
pub const RowIterator = opaque {};
pub const RowCells = opaque {};
pub const KeyEncoder = opaque {};
pub const KeyEvent = opaque {};
pub const MouseEncoder = opaque {};
pub const MouseEvent = opaque {};
pub const Formatter = opaque {};
pub const SelectionGesture = opaque {};
pub const SelectionGestureEvent = opaque {};
pub const ImageIterator = opaque {};
pub const KittyGraphics = opaque {};
pub const KittyGraphicsImage = opaque {};

// ---- Result codes (GhosttyResult) ----
pub const SUCCESS: c_int = 0;
pub const OUT_OF_MEMORY: c_int = -1;
pub const INVALID_VALUE: c_int = -2;
pub const OUT_OF_SPACE: c_int = -3;
pub const NO_VALUE: c_int = -4;
pub const IO_ERROR: c_int = -5;
pub const LIMIT_EXCEEDED: c_int = -6;
pub const REJECTED: c_int = -7;
pub const UNSUPPORTED: c_int = -8;

pub fn ok(result: c_int) bool {
    return result == SUCCESS;
}

// ---- Common value types ----
pub const String = extern struct { ptr: [*]const u8, len: usize };
pub const Buffer = extern struct { ptr: ?[*]u8, cap: usize, len: usize };
pub const CodepointBuffer = extern struct { ptr: ?[*]u32, cap: usize, len: usize };
pub const ColorRgb = extern struct { r: u8, g: u8, b: u8 };

pub const CursorStyle = enum(c_int) { bar = 0, block = 1, underline = 2, block_hollow = 3 };

pub const StyleColorTag = enum(u8) { none = 0, palette = 1, rgb = 2 };
pub const StyleColorValue = extern union { palette: u8, rgb: ColorRgb };
pub const StyleColor = extern struct { tag: StyleColorTag, value: StyleColorValue };
pub const Style = extern struct {
    fg_color: StyleColor,
    bg_color: StyleColor,
    underline_color: StyleColor,
    flags: u16,
    reserved: u16,
};
pub const STYLE_BOLD: u16 = 1 << 0;
pub const STYLE_ITALIC: u16 = 1 << 1;
pub const STYLE_FAINT: u16 = 1 << 2;
pub const STYLE_BLINK: u16 = 1 << 3;
pub const STYLE_INVERSE: u16 = 1 << 4;
pub const STYLE_INVISIBLE: u16 = 1 << 5;
pub const STYLE_STRIKETHROUGH: u16 = 1 << 6;
pub const STYLE_OVERLINE: u16 = 1 << 7;
pub const STYLE_UNDERLINE_MASK: u16 = 0x7 << 8;

pub fn underline(style: Style) u16 {
    return (style.flags & STYLE_UNDERLINE_MASK) >> 8;
}

// ---- Grid / selection geometry ----
pub const GridRef = extern struct { node: ?*anyopaque, x: u16, y: u16 };
pub const PointCoordinate = extern struct { x: u16, y: u32 };
pub const PointTag = enum(c_int) { active = 0, viewport = 1, screen = 2, history = 3 };
pub const PointValue = extern union { coordinate: PointCoordinate, _padding: [2]u64 };
pub const Point = extern struct { tag: PointTag, value: PointValue };
pub const Selection = extern struct { start: GridRef, end: GridRef, rectangle: bool };
pub const SurfacePosition = extern struct { x: f64, y: f64 };

pub fn viewportPoint(x: u16, y: u32) Point {
    return .{ .tag = .viewport, .value = .{ .coordinate = .{ .x = x, .y = y } } };
}

// ---- Sized render-state outputs ----
pub const RenderCursor = extern struct {
    size: usize,
    viewport_has_value: bool,
    viewport_x: u16,
    viewport_y: u16,
    wide_tail: bool,
    visible: bool,
    blinking: bool,
    password_input: bool,
    visual_style: CursorStyle,
};
pub const RenderColors = extern struct {
    size: usize,
    background: ColorRgb,
    foreground: ColorRgb,
    cursor: ColorRgb,
    cursor_has_value: bool,
    palette: [256]ColorRgb,
};
pub const RowSelection = extern struct { size: usize, start_x: u16, end_x: u16 };

pub extern "c" fn ghostty_sized_init(ptr: ?*anyopaque, size: usize) void;
pub fn sizedInit(value: anytype) void {
    ghostty_sized_init(value, @sizeOf(@TypeOf(value.*)));
}

// ---- Terminal options (GhosttyTerminalOption) ----
pub const TerminalOption = enum(c_int) {
    userdata = 1,
    write_pty = 2,
    bell = 3,
    title_changed = 6,
    color_foreground = 12,
    color_background = 13,
    color_cursor = 14,
    color_palette = 15,
    kitty_image_storage_limit = 16,
    kitty_image_medium_file = 17,
    kitty_image_medium_temp_file = 18,
    kitty_image_medium_shared_mem = 19,
    selection = 22,
    default_cursor_style = 23,
    default_cursor_blink = 24,
    glyph_protocol = 25,
    pwd_changed = 26,
    clipboard_write = 27,
    scrollback_max_bytes = 28,
    scrollback_max_lines = 29,
    desktop_notification = 30,
    progress_report = 31,
    title_report = 33,
    clipboard_read = 39,
    clipboard_write_max_bytes = 40,
    render_hold = 42,
    semantic_prompt = 43,
    xt_checksum_report = 45,
    resize_window = 48,
    apc_max_bytes_kitty = 21,
};

// ---- Terminal data (GhosttyTerminalData) ----
pub const TerminalData = enum(c_int) {
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    active_screen = 6,
    cursor_visible = 7,
    scrollbar = 9,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    selection = 31,
    viewport_active = 32,
    mouse_shape = 41,
    kitty_image_storage_limit = 26,
    kitty_image_medium_file = 27,
    kitty_image_medium_temp_file = 28,
    kitty_image_medium_shared_mem = 29,
    kitty_graphics = 30,
};

pub const Scrollbar = extern struct { total: u64, offset: u64, len: u64 };
pub const ScrollViewportTag = enum(c_int) { top = 0, bottom = 1, delta = 2, row = 3, delta_prompt = 4 };
pub const ScrollViewportValue = extern union { delta: isize, row: usize, delta_prompt: isize, _padding: [2]u64 };
pub const ScrollViewport = extern struct { tag: ScrollViewportTag, value: ScrollViewportValue };

pub fn scrollDelta(rows: isize) ScrollViewport {
    return .{ .tag = .delta, .value = .{ .delta = rows } };
}

// ---- Render-state data / options ----
pub const RenderData = enum(c_int) {
    cols = 1,
    rows = 2,
    dirty = 3,
    row_iterator = 4,
    color_background = 5,
    color_foreground = 6,
    color_cursor = 7,
    color_cursor_has_value = 8,
    color_palette = 9,
    cursor_visual_style = 10,
    cursor_visible = 11,
    cursor = 18,
    colors = 19,
    image_iterator = 22,
    image_placements_generation = 23,
};
pub const RenderOption = enum(c_int) { dirty = 1, overscan = 2 };
pub const Dirty = enum(c_int) { false = 0, partial = 1, full = 2 };
pub const RowData = enum(c_int) { dirty = 1, cells = 3, selection = 4, viewport_y = 6, id = 7 };

/// Opaque identity of a row across render-state updates. Two ids are equal
/// only when both words match; a zero id is never valid. Used to detect rows
/// that moved or were replaced even when they are not marked dirty.
pub const RowId = extern struct { bits: [2]u64 };
pub fn rowIdEql(a: RowId, b: RowId) bool {
    return a.bits[0] == b.bits[0] and a.bits[1] == b.bits[1];
}

/// Image protocols reported by the render-state image iterator.
pub const ImageProtocol = enum(c_int) { kitty = 0 };
/// Draw order relative to terminal text (see GhosttyImageLayer).
pub const ImageLayer = enum(c_int) { below_background = 0, below_text = 1, above_text = 2 };
/// Kind of a Kitty placement in the render-state image list.
pub const KittyPlacementKind = enum(c_int) { virtual = 0, relative = 1, fixed = 2 };

/// Per-placement data readable from the render-state image iterator.
pub const ImageData = enum(c_int) {
    protocol = 1,
    image_id = 2,
    image_generation = 3,
    layer = 4,
    z = 5,
    viewport_col = 6,
    viewport_row = 7,
    grid_cols = 8,
    grid_rows = 9,
    cell_offset_x = 10,
    cell_offset_y = 11,
    pixel_width = 12,
    pixel_height = 13,
    source_x = 14,
    source_y = 15,
    source_width = 16,
    source_height = 17,
    kitty_placement_id = 18,
    kitty_kind = 19,
};
pub const RowCellsData = enum(c_int) {
    raw = 1,
    style = 2,
    graphemes_len = 3,
    graphemes_buf = 4,
    bg_color = 5,
    fg_color = 6,
    selected = 7,
    has_styling = 8,
    graphemes_utf8 = 9,
};

// ---- Key input ----
pub const KeyAction = enum(c_int) { release = 0, press = 1, repeat = 2 };
pub const MODS_SHIFT: u16 = 1 << 0;
pub const MODS_CTRL: u16 = 1 << 1;
pub const MODS_ALT: u16 = 1 << 2;
pub const MODS_SUPER: u16 = 1 << 3;
pub const MODS_CAPS_LOCK: u16 = 1 << 4;
pub const MODS_NUM_LOCK: u16 = 1 << 5;

pub const Key = enum(c_int) {
    unidentified = 0,
    backquote = 1,
    backslash = 2,
    bracket_left = 3,
    bracket_right = 4,
    comma = 5,
    digit_0 = 6,
    digit_1 = 7,
    digit_2 = 8,
    digit_3 = 9,
    digit_4 = 10,
    digit_5 = 11,
    digit_6 = 12,
    digit_7 = 13,
    digit_8 = 14,
    digit_9 = 15,
    equal = 16,
    a = 20,
    b = 21,
    c = 22,
    d = 23,
    e = 24,
    f = 25,
    g = 26,
    h = 27,
    i = 28,
    j = 29,
    k = 30,
    l = 31,
    m = 32,
    n = 33,
    o = 34,
    p = 35,
    q = 36,
    r = 37,
    s = 38,
    t = 39,
    u = 40,
    v = 41,
    w = 42,
    x = 43,
    y = 44,
    z = 45,
    minus = 46,
    period = 47,
    quote = 48,
    semicolon = 49,
    slash = 50,
    alt_left = 51,
    alt_right = 52,
    backspace = 53,
    caps_lock = 54,
    context_menu = 55,
    control_left = 56,
    control_right = 57,
    enter = 58,
    meta_left = 59,
    meta_right = 60,
    shift_left = 61,
    shift_right = 62,
    space = 63,
    tab = 64,
    delete = 68,
    end = 69,
    home = 71,
    insert = 72,
    page_down = 73,
    page_up = 74,
    arrow_down = 75,
    arrow_left = 76,
    arrow_right = 77,
    arrow_up = 78,
    num_lock = 79,
    numpad_0 = 80,
    numpad_1 = 81,
    numpad_2 = 82,
    numpad_3 = 83,
    numpad_4 = 84,
    numpad_5 = 85,
    numpad_6 = 86,
    numpad_7 = 87,
    numpad_8 = 88,
    numpad_9 = 89,
    numpad_add = 90,
    numpad_decimal = 95,
    numpad_divide = 96,
    numpad_enter = 97,
    numpad_multiply = 104,
    numpad_subtract = 107,
    escape = 120,
    f1 = 121,
    f2 = 122,
    f3 = 123,
    f4 = 124,
    f5 = 125,
    f6 = 126,
    f7 = 127,
    f8 = 128,
    f9 = 129,
    f10 = 130,
    f11 = 131,
    f12 = 132,
    print_screen = 148,
    scroll_lock = 149,
    pause = 150,
};

pub const KeyEncoderOption = enum(c_int) {
    cursor_key_application = 1,
    keypad_key_application = 2,
    ignore_keypad_with_numlock = 3,
    alt_esc_prefix = 4,
    kitty_flags = 6,
    macos_option_as_alt = 7,
    backarrow_key_mode = 8,
};

// ---- Mouse input ----
pub const MouseAction = enum(c_int) { press = 0, release = 1, motion = 2 };
pub const MouseButton = enum(c_int) { unknown = 0, left = 1, right = 2, middle = 3, four = 4, five = 5 };
pub const MousePosition = extern struct { x: f64, y: f64 };
pub const MouseTracking = enum(c_int) { none = 0, normal = 2, button = 3, any = 4 };
pub const MouseFormat = enum(c_int) { sgr = 2, urxvt = 3, sgr_pixels = 4 };
pub const MouseEncoderOption = enum(c_int) { event = 1, format = 2, size = 3, any_button_pressed = 4, track_last_cell = 5 };
pub const MouseEncoderSize = extern struct {
    size: usize,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    padding_top: u32,
    padding_bottom: u32,
    padding_right: u32,
    padding_left: u32,
};

// ---- Paste ----
pub const ClipboardLocation = enum(c_int) { standard = 0, selection = 1, primary = 2 };
pub const PasteSource = enum(c_int) { clipboard = 0, text = 1 };
pub const MimeReaderFn = *const fn (?*anyopaque, String, Writer) callconv(.c) bool;
pub const MimeReader = extern struct { read: ?MimeReaderFn, userdata: ?*anyopaque };
pub const Paste = extern struct {
    size: usize,
    location: ClipboardLocation,
    source: PasteSource,
    mimes: ?[*]const String,
    mimes_len: usize,
    reader: MimeReader,
    allow_unsafe: bool,
};

// ---- Clipboard effect requests (frozen layouts) ----
pub const ClipboardContent = extern struct { mime: String, data: String };
pub const ClipboardWriteResult = enum(c_int) { success = 0, denied = 1, unsupported = 2, busy = 3, invalid_data = 4, io_error = 5 };
pub const ClipboardReadResult = enum(c_int) { success = 0, denied = 1, unsupported = 2, busy = 3, io_error = 4 };
pub const ClipboardWriteReply = extern struct { size: usize, result: ClipboardWriteResult, remember: bool };
pub const ClipboardReadReply = extern struct {
    size: usize,
    result: ClipboardReadResult,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
    available: ?[*]const String,
    available_len: usize,
    remember: bool,
};
pub const ClipboardWrite = extern struct {
    location: ClipboardLocation,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
    name: String,
    granted: bool,
    can_remember: bool,
    ctx: ?*const anyopaque,
    reply: ?*const fn (*const ClipboardWrite, *const ClipboardWriteReply) callconv(.c) void,
};
pub const ClipboardRead = extern struct {
    location: ClipboardLocation,
    mimes: ?[*]const String,
    mimes_len: usize,
    list: bool,
    name: String,
    granted: bool,
    can_remember: bool,
    ctx: ?*const anyopaque,
    reply: ?*const fn (*const ClipboardRead, *const ClipboardReadReply) callconv(.c) void,
};

// ---- IO writer ----
pub const WriterFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) bool;
pub const Writer = extern struct { write: ?WriterFn, userdata: ?*anyopaque };

// ---- Callback types ----
pub const WritePtyFn = *const fn (?*Terminal, ?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const TitleChangedFn = *const fn (?*Terminal, ?*anyopaque) callconv(.c) void;
pub const PwdChangedFn = *const fn (?*Terminal, ?*anyopaque) callconv(.c) void;
pub const BellFn = *const fn (?*Terminal, ?*anyopaque) callconv(.c) void;
pub const ClipboardWriteFn = *const fn (?*Terminal, ?*anyopaque, *const ClipboardWrite) callconv(.c) void;
pub const ClipboardReadFn = *const fn (?*Terminal, ?*anyopaque, *const ClipboardRead) callconv(.c) void;

// ---- Formatter ----
pub const FormatterFormat = enum(c_int) { plain = 0, vt = 1, html = 2 };
pub const FormatterOption = enum(c_int) { emit = 1, unwrap = 2, trim = 3, selection = 4, extras = 5 };

// ---- Kitty graphics images ----
/// Stored pixel formats. PNG/zlib payloads are decoded before storage, so
/// ghostty_kitty_graphics_image_get() never reports PNG or compressed data.
pub const KittyImageFormat = enum(c_int) { rgb = 0, rgba = 1, png = 2, gray_alpha = 3, gray = 4 };
pub const KittyImageData = enum(c_int) {
    id = 1,
    number = 2,
    width = 3,
    height = 4,
    format = 5,
    compression = 6,
    pixels = 7,
    expected_len = 8,
    generation = 9,
};
pub const KittyGraphicsData = enum(c_int) { placement_iterator = 1, generation = 2 };

// ---- Selection gesture ----
pub const GestureEventType = enum(c_int) { press = 0, release = 1, drag = 2, autoscroll_tick = 3, deep_press = 4 };
pub const GestureEventOption = enum(c_int) { ref = 1, position = 2, repeat_distance = 3, time_ns = 4, repeat_interval_ns = 5, word_boundary_codepoints = 6, behaviors = 7, rectangle = 8, geometry = 9, viewport = 10 };
pub const GestureGeometry = extern struct { columns: u32, cell_width: u32, padding_left: u32, screen_height: u32 };
pub const SelectWordOptions = extern struct { size: usize, ref: GridRef, boundary_codepoints: ?[*]const u32, boundary_codepoints_len: usize };
pub const SelectLineOptions = extern struct { size: usize, ref: GridRef, whitespace: ?[*]const u32, whitespace_len: usize, semantic_prompt_boundary: bool };

// ---- Lifecycle ----
pub extern "c" fn ghostty_terminal_new(allocator: ?*const anyopaque, terminal: *?*Terminal, cols: u16, rows: u16) c_int;
pub extern "c" fn ghostty_terminal_free(terminal: ?*Terminal) void;
pub extern "c" fn ghostty_terminal_reset(terminal: ?*Terminal) void;
pub extern "c" fn ghostty_terminal_resize(terminal: ?*Terminal, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) c_int;
pub extern "c" fn ghostty_terminal_set(terminal: ?*Terminal, option: TerminalOption, value: ?*const anyopaque) c_int;
pub extern "c" fn ghostty_terminal_vt_write(terminal: ?*Terminal, data: [*]const u8, len: usize) void;
pub extern "c" fn ghostty_terminal_get(terminal: ?*Terminal, data: TerminalData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_terminal_scroll_viewport(terminal: ?*Terminal, behavior: ScrollViewport) c_int;
pub extern "c" fn ghostty_terminal_grid_ref(terminal: ?*Terminal, point: Point, out_ref: *GridRef) c_int;
pub extern "c" fn ghostty_terminal_paste(terminal: ?*Terminal, paste: *const Paste, out_pasted: ?*bool) c_int;

// ---- Render state ----
pub extern "c" fn ghostty_render_state_new(allocator: ?*const anyopaque, state: *?*RenderState) c_int;
pub extern "c" fn ghostty_render_state_free(state: ?*RenderState) void;
pub extern "c" fn ghostty_render_state_update(state: ?*RenderState, terminal: ?*Terminal) c_int;
pub extern "c" fn ghostty_render_state_clean(state: ?*RenderState) c_int;
pub extern "c" fn ghostty_render_state_get(state: ?*RenderState, data: RenderData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_render_state_set(state: ?*RenderState, option: RenderOption, value: ?*const anyopaque) c_int;
pub extern "c" fn ghostty_render_state_row_iterator_new(allocator: ?*const anyopaque, out: *?*RowIterator) c_int;
pub extern "c" fn ghostty_render_state_row_iterator_free(iterator: ?*RowIterator) void;
pub extern "c" fn ghostty_render_state_row_iterator_next(iterator: ?*RowIterator) bool;
pub extern "c" fn ghostty_render_state_row_get(iterator: ?*RowIterator, data: RowData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_render_state_row_cells_new(allocator: ?*const anyopaque, out: *?*RowCells) c_int;
pub extern "c" fn ghostty_render_state_row_cells_free(cells: ?*RowCells) void;
pub extern "c" fn ghostty_render_state_row_cells_next(cells: ?*RowCells) bool;
pub extern "c" fn ghostty_render_state_row_cells_select(cells: ?*RowCells, x: u16) c_int;
pub extern "c" fn ghostty_render_state_row_cells_get(cells: ?*RowCells, data: RowCellsData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_render_state_row_iterator_next_dirty(iterator: ?*RowIterator, out_y: *u16) bool;
pub extern "c" fn ghostty_render_state_image_iterator_new(allocator: ?*const anyopaque, out: *?*ImageIterator) c_int;
pub extern "c" fn ghostty_render_state_image_iterator_free(iterator: ?*ImageIterator) void;
pub extern "c" fn ghostty_render_state_image_iterator_next(iterator: ?*ImageIterator) bool;
pub extern "c" fn ghostty_render_state_image_get(iterator: ?*ImageIterator, data: ImageData, out: ?*anyopaque) c_int;

// ---- Key encoder / event ----
pub extern "c" fn ghostty_key_encoder_new(allocator: ?*const anyopaque, encoder: *?*KeyEncoder) c_int;
pub extern "c" fn ghostty_key_encoder_free(encoder: ?*KeyEncoder) void;
pub extern "c" fn ghostty_key_encoder_set(encoder: ?*KeyEncoder, option: KeyEncoderOption, value: ?*const anyopaque) c_int;
pub extern "c" fn ghostty_key_encoder_set_from_terminal(encoder: ?*KeyEncoder, terminal: ?*Terminal) c_int;
pub extern "c" fn ghostty_key_encoder_encode(encoder: ?*KeyEncoder, event: ?*KeyEvent, buf: ?[*]u8, buf_len: usize, out_written: *usize) c_int;
pub extern "c" fn ghostty_key_event_new(allocator: ?*const anyopaque, event: *?*KeyEvent) c_int;
pub extern "c" fn ghostty_key_event_free(event: ?*KeyEvent) void;
pub extern "c" fn ghostty_key_event_set_action(event: ?*KeyEvent, action: KeyAction) c_int;
pub extern "c" fn ghostty_key_event_set_key(event: ?*KeyEvent, key: Key) c_int;
pub extern "c" fn ghostty_key_event_set_mods(event: ?*KeyEvent, mods: u16) c_int;
pub extern "c" fn ghostty_key_event_set_consumed_mods(event: ?*KeyEvent, mods: u16) c_int;
pub extern "c" fn ghostty_key_event_set_composing(event: ?*KeyEvent, composing: bool) c_int;
pub extern "c" fn ghostty_key_event_set_utf8(event: ?*KeyEvent, utf8: String) c_int;

// ---- Mouse encoder / event ----
pub extern "c" fn ghostty_mouse_encoder_new(allocator: ?*const anyopaque, encoder: *?*MouseEncoder) c_int;
pub extern "c" fn ghostty_mouse_encoder_free(encoder: ?*MouseEncoder) void;
pub extern "c" fn ghostty_mouse_encoder_set(encoder: ?*MouseEncoder, option: MouseEncoderOption, value: ?*const anyopaque) c_int;
pub extern "c" fn ghostty_mouse_encoder_set_from_terminal(encoder: ?*MouseEncoder, terminal: ?*Terminal) c_int;
pub extern "c" fn ghostty_mouse_encoder_encode(encoder: ?*MouseEncoder, event: ?*MouseEvent, buf: ?[*]u8, buf_len: usize, out_written: *usize) c_int;
pub extern "c" fn ghostty_mouse_event_new(allocator: ?*const anyopaque, event: *?*MouseEvent) c_int;
pub extern "c" fn ghostty_mouse_event_free(event: ?*MouseEvent) void;
pub extern "c" fn ghostty_mouse_event_set_action(event: ?*MouseEvent, action: MouseAction) c_int;
pub extern "c" fn ghostty_mouse_event_set_button(event: ?*MouseEvent, button: MouseButton) c_int;
pub extern "c" fn ghostty_mouse_event_clear_button(event: ?*MouseEvent) c_int;
pub extern "c" fn ghostty_mouse_event_set_mods(event: ?*MouseEvent, mods: u16) c_int;
pub extern "c" fn ghostty_mouse_event_set_position(event: ?*MouseEvent, position: MousePosition) c_int;

// ---- Selection ----
pub extern "c" fn ghostty_terminal_select_word(terminal: ?*Terminal, options: *const SelectWordOptions, out: *Selection) c_int;
pub extern "c" fn ghostty_terminal_select_line(terminal: ?*Terminal, options: *const SelectLineOptions, out: *Selection) c_int;
pub extern "c" fn ghostty_terminal_select_all(terminal: ?*Terminal, out: *Selection) c_int;

// ---- Formatter ----
pub extern "c" fn ghostty_formatter_terminal_new(allocator: ?*const anyopaque, formatter: *?*Formatter, terminal: ?*Terminal) c_int;
pub extern "c" fn ghostty_formatter_free(formatter: ?*Formatter) void;
pub extern "c" fn ghostty_formatter_set(formatter: ?*Formatter, option: FormatterOption, value: ?*const anyopaque) c_int;
pub extern "c" fn ghostty_formatter_format_buf(formatter: ?*Formatter, buf: ?[*]u8, buf_len: usize, out_written: *usize) c_int;

// ---- Kitty graphics ----
pub extern "c" fn ghostty_kitty_graphics_image(graphics: ?*KittyGraphics, image_id: u32) ?*KittyGraphicsImage;
pub extern "c" fn ghostty_kitty_graphics_get(graphics: ?*KittyGraphics, data: KittyGraphicsData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_kitty_graphics_image_get(image: ?*KittyGraphicsImage, data: KittyImageData, out: ?*anyopaque) c_int;
pub extern "c" fn ghostty_kitty_graphics_animation_tick(graphics: ?*KittyGraphics, now_ms: u64, next_ms: *u64) c_int;

// ---- Colors ----
pub extern "c" fn ghostty_color_palette_default(out: [*]ColorRgb) void;

test "sized struct layouts match the C ABI" {
    // Frozen/ documented sizes from ghostty/vt.h 1.0.1 (64-bit target).
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Style));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Selection));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ClipboardWrite));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GridRef));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RowId));
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(ColorRgb));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(StyleColor));
}
