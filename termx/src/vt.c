/* Minimal VT100/ANSI screen. See vt.h. */
#include "vt.h"

#include <stdlib.h>
#include <string.h>

enum {
    VT_GROUND,
    VT_ESC,
    VT_CSI,
    VT_OSC,
    VT_OSC_ESC, /* ESC seen inside OSC: next byte decides ST or not. */
    VT_CHARSET,
};

typedef struct {
    int state;
    int params[16];
    int nparams;
    int cur;      /* parameter being built, -1 when none yet. */
    int priv;     /* CSI '?' seen. */
    uint32_t utf8; /* partial code point. */
    int utf8_left;
    int16_t cur_fg; /* SGR foreground, -1 default. */
    int16_t cur_bg; /* SGR background, -1 default. */
    uint8_t cur_bold;
} vt_parse;

static vt_parse P;

/* A blank cell carries the default colours, except that an erase leaves
 * the current background behind (back colour erase, as xterm does). */
static void vt_blank_cell(vt_t *vt, int row, int col) {
    if (row < 0 || row >= VT_ROWS || col < 0 || col >= VT_COLS) return;
    vt->grid[row][col].ch = 0;
    vt->grid[row][col].fg = -1;
    vt->grid[row][col].bg = P.cur_bg;
    vt->grid[row][col].bold = 0;
}

static void vt_clear_grid(vt_t *vt) {
    for (int r = 0; r < VT_ROWS; r++)
        for (int c = 0; c < VT_COLS; c++) vt_blank_cell(vt, r, c);
    /* Clearing the grid resets the scroll region to the full screen
     * (ESC c and ED 2 both come through here). */
    vt->scroll_top = 0;
    vt->scroll_bottom = VT_ROWS - 1;
}

/* Free every scrollback line and forget them, keeping the allocated
 * array so the next scroll does not reallocate from scratch. */
static void vt_clear_scrollback(vt_t *vt) {
    for (int i = 0; i < vt->scrollback_count; i++) free(vt->scrollback[i]);
    vt->scrollback_count = 0;
}

static void vt_put_cell(vt_t *vt, int row, int col, uint32_t ch) {
    if (row < 0 || row >= VT_ROWS || col < 0 || col >= VT_COLS) return;
    vt->grid[row][col].ch = ch;
    vt->grid[row][col].fg = P.cur_fg;
    vt->grid[row][col].bg = P.cur_bg;
    vt->grid[row][col].bold = P.cur_bold;
}

static void vt_scroll_up(vt_t *vt) {
    /* Top line of the scroll region leaves the grid into scrollback;
     * only rows inside [scroll_top, scroll_bottom] move. Lines outside
     * the region are untouched. */
    char *line = NULL;
    size_t len = 0, cap = 0;
    for (int c = 0; c < VT_COLS; c++) {
        uint32_t ch = vt->grid[vt->scroll_top][c].ch;
        char buf[4];
        int n = 0;
        if (ch == 0) buf[n++] = ' ';
        else if (ch < 0x80) buf[n++] = (char)ch;
        else if (ch < 0x800) { buf[n++] = 0xC0 | (ch >> 6); buf[n++] = 0x80 | (ch & 0x3F); }
        else if (ch < 0x10000) { buf[n++] = 0xE0 | (ch >> 12); buf[n++] = 0x80 | ((ch >> 6) & 0x3F); buf[n++] = 0x80 | (ch & 0x3F); }
        else { buf[n++] = 0xF0 | (ch >> 18); buf[n++] = 0x80 | ((ch >> 12) & 0x3F); buf[n++] = 0x80 | ((ch >> 6) & 0x3F); buf[n++] = 0x80 | (ch & 0x3F); }
        if (len + (size_t)n + 1 > cap) {
            // Grow with a temp: if realloc fails the old buffer
            // must survive (assigning its result straight to line
            // would lose it), and the grid is left untouched.
            size_t new_cap = (cap + 64) * 2;
            char *grown = realloc(line, new_cap);
            if (!grown) { free(line); return; }
            line = grown;
            cap = new_cap;
        }
        memcpy(line + len, buf, (size_t)n);
        len += (size_t)n;
    }
    if (!line) return;
    while (len > 0 && line[len - 1] == ' ') len--;
    line[len] = '\0';
    if (vt->scrollback_count == vt->scrollback_cap) {
        if (vt->scrollback_cap >= VT_SCROLLBACK_MAX) {
            free(vt->scrollback[0]);
            memmove(vt->scrollback, vt->scrollback + 1, sizeof(char *) * (size_t)(vt->scrollback_cap - 1));
            vt->scrollback_count--;
        } else {
            // Grow with a temp: if realloc fails the old array must
            // survive. Assigning the result straight to scrollback
            // would lose it (NULL) while scrollback_cap was already
            // doubled, and the next scroll would write through NULL.
            int new_cap = vt->scrollback_cap ? vt->scrollback_cap * 2 : 64;
            char **grown = realloc(vt->scrollback, sizeof(char *) * (size_t)new_cap);
            if (!grown) { free(line); return; }
            vt->scrollback = grown;
            vt->scrollback_cap = new_cap;
        }
    }
    vt->scrollback[vt->scrollback_count++] = line;
    memmove(vt->grid[vt->scroll_top], vt->grid[vt->scroll_top + 1],
            sizeof(vt_cell) * VT_COLS * (vt->scroll_bottom - vt->scroll_top));
    for (int c = 0; c < VT_COLS; c++) vt_blank_cell(vt, vt->scroll_bottom, c);
}

static void vt_newline(vt_t *vt) {
    vt->pending_wrap = 0;
    vt->cx = 0;
    if (vt->cy == vt->scroll_bottom) vt_scroll_up(vt);
    else if (vt->cy < VT_ROWS - 1) vt->cy++;
    /* cy below the region and already on the last row: stay put. */
}

static void vt_put_char(vt_t *vt, uint32_t ch) {
    if (ch == '\r') { vt->cx = 0; vt->pending_wrap = 0; return; }
    if (ch == '\n') { vt_newline(vt); return; }
    if (ch == '\b') { if (vt->cx > 0) vt->cx--; vt->pending_wrap = 0; return; }
    if (ch == '\t') {
        /* A tab is a cursor move, so it clears a pending wrap; without
         * this the tab's own newline plus the wrap would skip a line. */
        vt->pending_wrap = 0;
        vt->cx = (vt->cx + 8) & ~7; if (vt->cx >= VT_COLS) vt_newline(vt); return;
    }
    if (ch < 0x20 || ch == 0x7F) return;
    /* Deferred wrap: a full 80-column line sets pending_wrap instead
     * of wrapping at once, so the cursor stays on the last column
     * until the next printable char (which wraps first). A CR, LF,
     * backspace, tab, or CSI cursor move in between cancels it, so
     * the cursor never lands on the wrong line. */
    if (vt->pending_wrap) { vt_newline(vt); vt->pending_wrap = 0; }
    vt_put_cell(vt, vt->cy, vt->cx, ch);
    vt->cx++;
    if (vt->cx >= VT_COLS) vt->pending_wrap = 1;
}

static int vt_param(vt_t *vt, int i, int def) {
    (void)vt;
    if (i >= P.nparams) return def;
    int v = P.params[i];
    return v == 0 ? def : v;
}

/* Map an RGB triple to the nearest xterm 256-colour index. The cube
 * (16-231) uses levels 0, 95, 135, 175, 215, 255 per channel; the
 * grey ramp (232-255) is 8 + 10*i. Whichever is closer wins. */
static int vt_rgb_to_256(int r, int g, int b) {
    static const int levels[6] = {0, 95, 135, 175, 215, 255};
    int r6 = 0, g6 = 0, b6 = 0;
    for (int i = 0; i < 6; i++) {
        if (abs(r - levels[i]) < abs(r - levels[r6])) r6 = i;
        if (abs(g - levels[i]) < abs(g - levels[g6])) g6 = i;
        if (abs(b - levels[i]) < abs(b - levels[b6])) b6 = i;
    }
    int cr = levels[r6], cg = levels[g6], cb = levels[b6];
    int dcube = (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb);
    int avg = (r + g + b) / 3;
    int gr = (avg - 8 + 5) / 10;
    if (gr < 0) gr = 0;
    if (gr > 23) gr = 23;
    int grey = 8 + gr * 10;
    int dgrey = (r - grey) * (r - grey) + (g - grey) * (g - grey) + (b - grey) * (b - grey);
    if (dgrey < dcube) return 232 + gr;
    return 16 + 36 * r6 + 6 * g6 + b6;
}

static void vt_csi(vt_t *vt, uint8_t final) {
    int n, r, c;
    switch (final) {
    case 'H': case 'f':
        r = vt_param(vt, 0, 1) - 1; c = vt_param(vt, 1, 1) - 1;
        if (r < 0) r = 0; if (r >= VT_ROWS) r = VT_ROWS - 1;
        if (c < 0) c = 0; if (c >= VT_COLS) c = VT_COLS - 1;
        vt->cy = r; vt->cx = c;
        vt->pending_wrap = 0;
        break;
    case 'A': vt->cy -= vt_param(vt, 0, 1); if (vt->cy < 0) vt->cy = 0; vt->pending_wrap = 0; break;
    case 'B': vt->cy += vt_param(vt, 0, 1); if (vt->cy >= VT_ROWS) vt->cy = VT_ROWS - 1; vt->pending_wrap = 0; break;
    case 'C': vt->cx += vt_param(vt, 0, 1); if (vt->cx >= VT_COLS) vt->cx = VT_COLS - 1; vt->pending_wrap = 0; break;
    case 'D': vt->cx -= vt_param(vt, 0, 1); if (vt->cx < 0) vt->cx = 0; vt->pending_wrap = 0; break;
    case 'G': case '`':
        c = vt_param(vt, 0, 1) - 1;
        vt->cx = c < 0 ? 0 : (c >= VT_COLS ? VT_COLS - 1 : c);
        vt->pending_wrap = 0;
        break;
    case 'd':
        r = vt_param(vt, 0, 1) - 1;
        vt->cy = r < 0 ? 0 : (r >= VT_ROWS ? VT_ROWS - 1 : r);
        vt->pending_wrap = 0;
        break;
    case 'J':
        n = vt_param(vt, 0, 0);
        if (n == 0) {
            for (int i = vt->cx; i < VT_COLS; i++) vt_blank_cell(vt, vt->cy, i);
            for (int i = vt->cy + 1; i < VT_ROWS; i++)
                for (int j = 0; j < VT_COLS; j++) vt_blank_cell(vt, i, j);
        } else if (n == 1) {
            /* From the start of the screen to the cursor, inclusive. */
            for (int i = 0; i <= vt->cx; i++) vt_blank_cell(vt, vt->cy, i);
            for (int i = 0; i < vt->cy; i++)
                for (int j = 0; j < VT_COLS; j++) vt_blank_cell(vt, i, j);
        } else if (n == 2) {
            /* Whole visible screen, cursor home — and the scrollback
             * too. This terminal renders scrollback inline above the
             * grid in the same text view, so leaving it would keep
             * the old output on screen after a clear (the `clear`
             * command sends ESC[H ESC[2J). */
            vt_clear_grid(vt);
            vt_clear_scrollback(vt);
            vt->cx = 0; vt->cy = 0;
            vt->pending_wrap = 0;
        } else if (n == 3) {
            /* xterm extension: clear the scrollback only. */
            vt_clear_scrollback(vt);
        }
        break;
    case 'K':
        n = vt_param(vt, 0, 0);
        if (n == 0) { for (int i = vt->cx; i < VT_COLS; i++) vt_blank_cell(vt, vt->cy, i); }
        else if (n == 1) { for (int i = 0; i <= vt->cx; i++) vt_blank_cell(vt, vt->cy, i); }
        else if (n == 2) { for (int i = 0; i < VT_COLS; i++) vt_blank_cell(vt, vt->cy, i); }
        break;
    case 'm': /* SGR: 0 reset, 1/22 bold, 30-37/90-97 fg, 40-47/100-107 bg,
                 38;5;n / 48;5;n extended colours, 39/49 default. */
        if (P.nparams == 0) {
            P.cur_fg = -1; P.cur_bg = -1; P.cur_bold = 0;
            break;
        }
        for (int i = 0; i < P.nparams; i++) {
            int p = P.params[i];
            if (p == 0) { P.cur_fg = -1; P.cur_bg = -1; P.cur_bold = 0; }
            else if (p == 1) P.cur_bold = 1;
            else if (p == 22) P.cur_bold = 0;
            else if (p >= 30 && p <= 37) P.cur_fg = (int16_t)(p - 30);
            else if (p >= 40 && p <= 47) P.cur_bg = (int16_t)(p - 40);
            else if (p >= 90 && p <= 97) P.cur_fg = (int16_t)(p - 90 + 8);
            else if (p >= 100 && p <= 107) P.cur_bg = (int16_t)(p - 100 + 8);
            else if (p == 38 || p == 48) {
                if (i + 2 < P.nparams && P.params[i + 1] == 5) {
                    int c = P.params[i + 2];
                    if (c >= 0 && c <= 255) {
                        if (p == 38) P.cur_fg = (int16_t)c;
                        else P.cur_bg = (int16_t)c;
                    }
                    i += 2;
                } else if (i + 4 < P.nparams && P.params[i + 1] == 2) {
                    /* Truecolor 38;2;r;g;b / 48;2;r;g;b: the grid
                     * only stores xterm 256-colour indices, so map
                     * the RGB to the nearest cube or grey entry. The
                     * r, g, b values are consumed here (i += 4) so
                     * they are not misread as separate SGR codes. */
                    int r = P.params[i + 2], g = P.params[i + 3], b = P.params[i + 4];
                    if (r >= 0 && r <= 255 && g >= 0 && g <= 255 && b >= 0 && b <= 255) {
                        int c = vt_rgb_to_256(r, g, b);
                        if (p == 38) P.cur_fg = (int16_t)c;
                        else P.cur_bg = (int16_t)c;
                    }
                    i += 4;
                }
            }
            else if (p == 39) P.cur_fg = -1;
            else if (p == 49) P.cur_bg = -1;
        }
        break;
    case 's': vt->saved_cx = vt->cx; vt->saved_cy = vt->cy; vt->pending_wrap = 0; break;
    case 'u': vt->cx = vt->saved_cx; vt->cy = vt->saved_cy; vt->pending_wrap = 0; break;
    case 'h':
        if (P.priv) {
            int mode = vt_param(vt, 0, 0);
            if (mode == 25) {
                /* CSI ?25h: show the cursor. */
                vt->cursor_visible = 1;
            } else if ((mode == 1049 || mode == 1047) && !vt->in_alt) {
                /* Alternate screen: save the main screen and its
                 * cursor, clear the grid, start at the top. */
                memcpy(vt->alt_grid, vt->grid, sizeof vt->grid);
                vt->alt_cx = vt->cx; vt->alt_cy = vt->cy;
                vt_clear_grid(vt);
                vt->cx = 0; vt->cy = 0;
                vt->pending_wrap = 0;
                vt->in_alt = 1;
            }
        }
        break;
    case 'l':
        if (P.priv) {
            int mode = vt_param(vt, 0, 0);
            if (mode == 25) {
                /* CSI ?25l: hide the cursor. */
                vt->cursor_visible = 0;
            } else if ((mode == 1049 || mode == 1047) && vt->in_alt) {
                /* Back to the main screen: restore what ?1049h saved. */
                memcpy(vt->grid, vt->alt_grid, sizeof vt->grid);
                vt->cx = vt->alt_cx; vt->cy = vt->alt_cy;
                vt->pending_wrap = 0;
                vt->in_alt = 0;
            }
        }
        break;
    case 'r': {
        /* DECSTBM: CSI top;bottom r, 1-based, defaults to the full
         * screen. The scroll region is inclusive on both ends. */
        int top = vt_param(vt, 0, 1) - 1;
        int bottom = vt_param(vt, 1, VT_ROWS) - 1;
        if (top < 0) top = 0; if (top >= VT_ROWS) top = VT_ROWS - 1;
        if (bottom < 0) bottom = 0; if (bottom >= VT_ROWS) bottom = VT_ROWS - 1;
        if (top > bottom) { top = 0; bottom = VT_ROWS - 1; }
        vt->scroll_top = top;
        vt->scroll_bottom = bottom;
        break;
    }
    default:
        break;
    }
}

void vt_init(vt_t *vt) {
    memset(vt, 0, sizeof *vt);
    memset(&P, 0, sizeof P);
    P.cur = -1;
    P.cur_fg = -1;
    P.cur_bg = -1;
    /* memset zeroes scroll_top (0, correct) but scroll_bottom needs
     * the last row, and the cursor starts visible. pending_wrap and
     * in_alt start at 0, which memset already gives them. */
    vt->scroll_bottom = VT_ROWS - 1;
    vt->cursor_visible = 1;
    /* memset leaves every cell's fg/bg at 0 (palette black); default is -1. */
    for (int r = 0; r < VT_ROWS; r++)
        for (int c = 0; c < VT_COLS; c++) {
            vt->grid[r][c].fg = -1;
            vt->grid[r][c].bg = -1;
        }
}

void vt_free(vt_t *vt) {
    for (int i = 0; i < vt->scrollback_count; i++) free(vt->scrollback[i]);
    free(vt->scrollback);
    vt->scrollback = NULL;
    vt->scrollback_count = vt->scrollback_cap = 0;
}

void vt_feed(vt_t *vt, const uint8_t *bytes, size_t len) {
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (P.state) {
        case VT_GROUND:
            if (b == 0x1B) { P.state = VT_ESC; break; }
            if (b < 0x80) { vt_put_char(vt, b); vt->dirty = 1; break; }
            if ((b & 0xE0) == 0xC0) { P.utf8 = b & 0x1F; P.utf8_left = 1; break; }
            if ((b & 0xF0) == 0xE0) { P.utf8 = b & 0x0F; P.utf8_left = 2; break; }
            if ((b & 0xF8) == 0xF0) { P.utf8 = b & 0x07; P.utf8_left = 3; break; }
            if ((b & 0xC0) == 0x80 && P.utf8_left > 0) {
                P.utf8 = (P.utf8 << 6) | (b & 0x3F);
                if (--P.utf8_left == 0) { vt_put_char(vt, P.utf8); vt->dirty = 1; }
                break;
            }
            /* Stray continuation or invalid byte: drop it. */
            P.utf8_left = 0;
            break;
        case VT_ESC:
            if (b == '[') {
                P.state = VT_CSI;
                P.nparams = 0; P.cur = -1; P.priv = 0;
                memset(P.params, 0, sizeof P.params);
            } else if (b == ']') {
                P.state = VT_OSC;
            } else if (b == '(' || b == ')' || b == '#' || b == '%') {
                P.state = VT_CHARSET;
            } else if (b == '7') { vt->saved_cx = vt->cx; vt->saved_cy = vt->cy; P.state = VT_GROUND; }
            else if (b == '8') { vt->cx = vt->saved_cx; vt->cy = vt->saved_cy; P.state = VT_GROUND; }
            else if (b == 'c') { vt_clear_grid(vt); vt_clear_scrollback(vt); P.cur_fg = -1; P.cur_bg = -1; P.cur_bold = 0; vt->cx = 0; vt->cy = 0; vt->pending_wrap = 0; vt->cursor_visible = 1; vt->dirty = 1; P.state = VT_GROUND; }
            else if (b == '=' || b == '>') { P.state = VT_GROUND; }
            else { P.state = VT_GROUND; }
            break;
        case VT_CSI:
            if (b == '?') { P.priv = 1; break; }
            if (b >= '0' && b <= '9') {
                if (P.cur < 0) { P.cur = 0; if (P.nparams < 16) P.params[P.nparams] = 0; }
                if (P.nparams < 16) P.params[P.nparams] = P.params[P.nparams] * 10 + (b - '0');
                break;
            }
            if (b == ';') {
                if (P.nparams < 16) P.nparams++;
                P.cur = -1;
                break;
            }
            if (b >= 0x20 && b <= 0x2F) break; /* intermediates: ignored. */
            if (b >= 0x40 && b <= 0x7E) {
                // Count this parameter, capped at the array: without
                // the cap a sequence with more than 16 parameters
                // pushes nparams to 17 and vt_csi's SGR loop reads
                // params[16], past the end of the array (proven with
                // -fsanitize=bounds on a 20-parameter SGR).
                if ((P.cur >= 0 || P.nparams > 0) && P.nparams < 16) P.nparams++;
                vt_csi(vt, b);
                vt->dirty = 1;
                P.state = VT_GROUND;
                break;
            }
            P.state = VT_GROUND;
            break;
        case VT_OSC:
            if (b == 0x07) P.state = VT_GROUND;
            else if (b == 0x1B) P.state = VT_OSC_ESC;
            break;
        case VT_OSC_ESC:
            /* ESC inside OSC: only backslash completes the ST
             * terminator (both bytes are swallowed, nothing is
             * passed to output). Anything else is just OSC content. */
            if (b == '\\') P.state = VT_GROUND;
            else P.state = VT_OSC;
            break;
        case VT_CHARSET:
            P.state = VT_GROUND;
            break;
        }
        /* Continuation bytes while in an escape state: drop. */
    }
}

static void append_utf8(char **out, size_t *len, size_t *cap, uint32_t ch) {
    char buf[4];
    int n = 0;
    if (ch == 0) buf[n++] = ' ';
    else if (ch < 0x80) buf[n++] = (char)ch;
    else if (ch < 0x800) { buf[n++] = 0xC0 | (ch >> 6); buf[n++] = 0x80 | (ch & 0x3F); }
    else if (ch < 0x10000) { buf[n++] = 0xE0 | (ch >> 12); buf[n++] = 0x80 | ((ch >> 6) & 0x3F); buf[n++] = 0x80 | (ch & 0x3F); }
    else { buf[n++] = 0xF0 | (ch >> 18); buf[n++] = 0x80 | ((ch >> 12) & 0x3F); buf[n++] = 0x80 | ((ch >> 6) & 0x3F); buf[n++] = 0x80 | (ch & 0x3F); }
    if (*len + (size_t)n + 1 > *cap) { *cap = (*cap + 256) * 2; *out = realloc(*out, *cap); }
    if (!*out) return;
    memcpy(*out + *len, buf, (size_t)n);
    *len += (size_t)n;
}

char *vt_render(vt_t *vt) {
    char *out = NULL;
    size_t len = 0, cap = 0;
    for (int i = 0; i < vt->scrollback_count; i++) {
        const char *line = vt->scrollback[i];
        size_t n = strlen(line);
        if (len + n + 2 > cap) { cap = (len + n + 2) * 2 + 256; out = realloc(out, cap); if (!out) return NULL; }
        memcpy(out + len, line, n);
        len += n;
        out[len++] = '\n';
    }
    for (int r = 0; r < VT_ROWS; r++) {
        int last = VT_COLS - 1;
        while (last >= 0 && vt->grid[r][last].ch == 0) last--;
        for (int c = 0; c <= last; c++) append_utf8(&out, &len, &cap, vt->grid[r][c].ch);
        if (r < VT_ROWS - 1) {
            if (len + 2 > cap) { cap = (len + 2) * 2 + 256; out = realloc(out, cap); if (!out) return NULL; }
            out[len++] = '\n';
        }
    }
    if (!out) { out = malloc(1); if (out) out[0] = '\0'; return out; }
    out[len] = '\0';
    vt->dirty = 0;
    return out;
}
