/* Minimal VT100/ANSI terminal screen for TermX (shared with CrateTerm).
 *
 * A fixed 80x25 grid plus scrollback, fed with raw guest bytes — the size
 * NewTerm uses by default. It handles the sequences a Linux login prompt
 * and a shell actually emit: printable text (UTF-8), CR/LF/BS/TAB, and
 * CSI H/f/A/B/C/D/G/d/J/K/m/s/u/h/l/r, plus ESC 7/8 and ESC c. SGR
 * colours are parsed into per-cell fg/bg (xterm 256-colour indices, -1
 * for default) and bold, so the view can render them; scrollback lines
 * stay plain text. No dependency on SwiftTerm or any Swift code.
 */

#ifndef CRATETERM_VT_H
#define CRATETERM_VT_H

#include <stddef.h>
#include <stdint.h>

#define VT_COLS 80
#define VT_ROWS 25
#define VT_SCROLLBACK_MAX 2000

typedef struct {
    uint32_t ch; /* Unicode scalar; 0 is a blank cell. */
    int16_t fg;  /* xterm colour 0-255, or -1 for the default foreground. */
    int16_t bg;  /* xterm colour 0-255, or -1 for the default background. */
    uint8_t bold;
} vt_cell;

typedef struct {
    vt_cell grid[VT_ROWS][VT_COLS];
    int cx, cy;
    int saved_cx, saved_cy;
    char **scrollback; /* UTF-8 lines, oldest first. */
    int scrollback_count;
    int scrollback_cap;
    int dirty; /* grid or scrollback changed since last render. */
} vt_t;

void vt_init(vt_t *vt);
void vt_free(vt_t *vt);
/* Feed raw bytes from the guest. */
void vt_feed(vt_t *vt, const uint8_t *bytes, size_t len);
/* Rendered text: scrollback lines then the grid, trailing spaces trimmed.
 * Caller frees the result. Returns NULL on allocation failure. */
char *vt_render(vt_t *vt);

#endif
