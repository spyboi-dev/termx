/* Minimal VT100/ANSI terminal screen for TermX (shared with CrateTerm).
 *
 * A fixed 80x25 grid plus scrollback, fed with raw guest bytes — the size
 * NewTerm uses by default. It handles the sequences a Linux login prompt
 * and a shell actually emit: printable text (UTF-8), CR/LF/BS/TAB, and
 * CSI H/f/A/B/C/D/G/d/J/K/m/s/u/h/l/r, plus ESC 7/8 and ESC c. SGR
 * colours are parsed into per-cell fg/bg (xterm 256-colour indices, -1
 * for default) and bold, so the view can render them. The scrollback
 * keeps the cells, not plain text, so scrolling up shows the colours
 * the lines were printed with; trailing blanks are trimmed only at
 * render time, the same as a grid row. No dependency on SwiftTerm or
 * any Swift code.
 *
 * The 80 columns are not arbitrary: the guest console is a serial ttyS0
 * whose winsize the kernel leaves at 0, so guest programs fall back to
 * 80 columns, and there is no host-side channel to tell the guest a
 * different size (the runtime has no winsize API, and injecting `stty`
 * keystrokes into the user's live shell is unsafe). The grid must match
 * what the guest actually emits: a narrower grid would make vt itself
 * wrap the guest's 80-column lines and interleave two-column output
 * (fastfetch, apt progress bars) all over again. Lines longer than the
 * screen do not wrap in the view either — the text container is wider
 * than the screen with widthTracksTextView off, so they scroll
 * horizontally instead.
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
    /* Scrollback: one flat array of scrollback_cap rows of VT_COLS
     * cells, oldest first. A row is stored whole (80 cells); the
     * view trims trailing blanks when it renders the row. Keeping
     * cells (not plain text) is what preserves colour in scrollback.
     * 2000 rows x 80 cells x 12 bytes is ~1.9 MB at the cap. */
    vt_cell *scrollback;
    int scrollback_count;
    int scrollback_cap; /* capacity in rows; never above VT_SCROLLBACK_MAX. */
    /* Monotonic counters so the view can render incrementally: seq
     * counts every line ever pushed into scrollback, dropped counts
     * the lines that fell off the front once the cap was reached.
     * The view remembers both at its last render and only appends
     * the lines with a higher seq, deleting the dropped ones from
     * the front of its text. Neither is reset by a scrollback clear;
     * a clear is detected by the count shrinking and by
     * clear_generation changing (see below). */
    uint64_t scrollback_seq;
    uint64_t scrollback_dropped;
    /* Monotonic clear generation, incremented by every scrollback
     * clear. The view remembers it at its last render and forces a
     * full rebuild when it changes: a clear followed by enough new
     * output within one flush interval can leave scrollback_count
     * above the rendered count, so the count alone cannot detect
     * the clear (see vt_clear_scrollback). */
    uint64_t clear_generation;
    int dirty; /* grid or scrollback changed since last render. */
    int bell; /* BEL (0x07) received since the view last checked. Set
                 by vt_put_char; the view clears it when it rings the
                 bell, so a bell is never rung twice or lost. */
    int pending_wrap; /* cursor past the last column: wrap on the next
                         printable char instead of at once (deferred
                         wrap, as xterm does). */
    int scroll_top, scroll_bottom; /* DECSTBM region, 0-based inclusive. */
    vt_cell alt_grid[VT_ROWS][VT_COLS]; /* saved main screen for CSI ?1049h. */
    int alt_cx, alt_cy; /* saved main cursor for CSI ?1049h. */
    int in_alt; /* on the alternate screen (CSI ?1049h / ?1047h). */
    int cursor_visible; /* CSI ?25h / ?25l; the view reads this. */
} vt_t;

void vt_init(vt_t *vt);
void vt_free(vt_t *vt);
/* Feed raw bytes from the guest. */
void vt_feed(vt_t *vt, const uint8_t *bytes, size_t len);
/* Rendered text: scrollback lines then the grid, trailing spaces trimmed.
 * Caller frees the result. Returns NULL on allocation failure. */
char *vt_render(vt_t *vt);
/* 1 when nothing has been printed: the current grid is all blank and
 * the scrollback is empty. The terminal uses it after a clear-on-boot
 * to tell whether the guest has printed a prompt yet — a clear wipes
 * both, so any content means output arrived after the clear. */
int vt_is_empty(vt_t *vt);
/* Decode one UTF-8 sequence starting at p (len bytes available).
 * Returns the bytes consumed (1-4) for a complete valid sequence and
 * sets *cp; returns 0 if the bytes are invalid; returns -1 if the
 * buffer ends mid-sequence. Strict: rejects overlongs, surrogates,
 * and code points above U+10FFFF. This is the one UTF-8 decoder: the
 * incremental parser in vt_feed and any whole-string decoder both
 * use it, so the validation rules cannot drift apart. */
int vt_utf8_decode(const uint8_t *p, size_t len, uint32_t *cp);

#endif
