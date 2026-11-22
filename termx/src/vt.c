/* Minimal VT100/ANSI screen. See vt.h. */
#include "vt.h"

#include <stdlib.h>
#include <string.h>

enum {
    VT_GROUND,
    VT_ESC,
    VT_CSI,
    VT_OSC,
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
}

static void vt_put_cell(vt_t *vt, int row, int col, uint32_t ch) {
    if (row < 0 || row >= VT_ROWS || col < 0 || col >= VT_COLS) return;
    vt->grid[row][col].ch = ch;
    vt->grid[row][col].fg = P.cur_fg;
    vt->grid[row][col].bg = P.cur_bg;
    vt->grid[row][col].bold = P.cur_bold;
}

static void vt_scroll_up(vt_t *vt) {
    /* Top line leaves the grid into scrollback. */
    char *line = NULL;
    size_t len = 0, cap = 0;
    for (int c = 0; c < VT_COLS; c++) {
        uint32_t ch = vt->grid[0][c].ch;
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
    memmove(vt->grid[0], vt->grid[1], sizeof(vt_cell) * VT_COLS * (VT_ROWS - 1));
    for (int c = 0; c < VT_COLS; c++) vt_blank_cell(vt, VT_ROWS - 1, c);
}

static void vt_newline(vt_t *vt) {
    vt->cx = 0;
    if (vt->cy == VT_ROWS - 1) vt_scroll_up(vt);
    else vt->cy++;
}

static void vt_put_char(vt_t *vt, uint32_t ch) {
    if (ch == '\r') { vt->cx = 0; return; }
    if (ch == '\n') { vt_newline(vt); return; }
    if (ch == '\b') { if (vt->cx > 0) vt->cx--; return; }
    if (ch == '\t') { vt->cx = (vt->cx + 8) & ~7; if (vt->cx >= VT_COLS) vt_newline(vt); return; }
    if (ch < 0x20 || ch == 0x7F) return;
    vt_put_cell(vt, vt->cy, vt->cx, ch);
    vt->cx++;
    if (vt->cx >= VT_COLS) vt_newline(vt);
}

static int vt_param(vt_t *vt, int i, int def) {
    (void)vt;
    if (i >= P.nparams) return def;
    int v = P.params[i];
    return v == 0 ? def : v;
}

static void vt_csi(vt_t *vt, uint8_t final) {
    int n, r, c;
    switch (final) {
    case 'H': case 'f':
        r = vt_param(vt, 0, 1) - 1; c = vt_param(vt, 1, 1) - 1;
        if (r < 0) r = 0; if (r >= VT_ROWS) r = VT_ROWS - 1;
        if (c < 0) c = 0; if (c >= VT_COLS) c = VT_COLS - 1;
        vt->cy = r; vt->cx = c;
        break;
    case 'A': vt->cy -= vt_param(vt, 0, 1); if (vt->cy < 0) vt->cy = 0; break;
    case 'B': vt->cy += vt_param(vt, 0, 1); if (vt->cy >= VT_ROWS) vt->cy = VT_ROWS - 1; break;
    case 'C': vt->cx += vt_param(vt, 0, 1); if (vt->cx >= VT_COLS) vt->cx = VT_COLS - 1; break;
    case 'D': vt->cx -= vt_param(vt, 0, 1); if (vt->cx < 0) vt->cx = 0; break;
    case 'G': case '`':
        c = vt_param(vt, 0, 1) - 1;
        vt->cx = c < 0 ? 0 : (c >= VT_COLS ? VT_COLS - 1 : c);
        break;
    case 'd':
        r = vt_param(vt, 0, 1) - 1;
        vt->cy = r < 0 ? 0 : (r >= VT_ROWS ? VT_ROWS - 1 : r);
        break;
    case 'J':
        n = vt_param(vt, 0, 0);
        if (n == 2 || n == 3) {
            vt_clear_grid(vt);
            vt->cx = 0; vt->cy = 0;
        } else if (n == 0) {
            for (int i = vt->cx; i < VT_COLS; i++) vt_blank_cell(vt, vt->cy, i);
            for (int i = vt->cy + 1; i < VT_ROWS; i++)
                for (int j = 0; j < VT_COLS; j++) vt_blank_cell(vt, i, j);
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
                }
            }
            else if (p == 39) P.cur_fg = -1;
            else if (p == 49) P.cur_bg = -1;
        }
        break;
    case 's': vt->saved_cx = vt->cx; vt->saved_cy = vt->cy; break;
    case 'u': vt->cx = vt->saved_cx; vt->cy = vt->saved_cy; break;
    case 'h': case 'l': case 'r':
        break;
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
            else if (b == 'c') { vt_clear_grid(vt); P.cur_fg = -1; P.cur_bg = -1; P.cur_bold = 0; vt->cx = 0; vt->cy = 0; vt->dirty = 1; P.state = VT_GROUND; }
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
