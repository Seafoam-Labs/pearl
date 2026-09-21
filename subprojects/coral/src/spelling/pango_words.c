/* PangoLogAttr uses C bitfields, which Zig 0.16 cannot import directly.
 * This adapter exposes only word-boundary flags. All checking policy is Zig. */
#include <pango/pango.h>
void coral_word_breaks(const char *text, int bytes, unsigned char *breaks, int count) {
    PangoLogAttr *attrs = g_new0(PangoLogAttr, count);
    pango_get_log_attrs(text, bytes, -1, pango_language_get_default(), attrs, count);
    for (int i = 0; i < count; i++)
        breaks[i] = (attrs[i].is_word_start ? 1 : 0) | (attrs[i].is_word_end ? 2 : 0);
    g_free(attrs);
}
