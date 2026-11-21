; MD - a Markdown editor for the Commander X16  (Prog8, target cx16)
;
; A modeless editor with Markdown syntax colouring and soft line wrap. Ctrl-P (or F5)
; switches to a rendered preview with real bold/italic fonts, headings, lists, block
; quotes, rules, fenced code and boxed tables; Ctrl-G (or F4) opens a table-of-contents
; jump menu. A line containing only [TOC] becomes a contents list in the preview.
; (It started life as a C / cc65 program; Prog8 gives smaller, faster code.)
;
; HOW IT WORKS
;   * The document is NOT loaded into memory. Opening a file only scans it and cuts it into
;     1 KB pages (runs of whole lines); a page's text is read from the file when it is first
;     needed (as you move through the document) and cached in BANKED RAM, and unchanged pages
;     are dropped from the cache again when room is needed. Only CHANGED pages must stay in
;     memory (until the next save), so files far larger than memory can be opened. Two
;     page-sized windows in main RAM hold the pages in use. Lines are addressed by number
;     through lp(l) / linelen(l); edits go through splice(). Undo is copy-on-write on whole
;     pages. See "paged document store" in the code.
;   * Screen output goes straight into VERA's text map in ISO mode ($0F), so a screen
;     code is plain ASCII. The editor wraps long lines on screen; one logical line may
;     use several screen rows (see rows_of / draw_logical / cursor_xy).
;   * FONTS: at start-up build_fonts() reads the 8x8 ISO glyphs from VERA's character set
;     and writes bold and italic variants (and box-drawing / bullet glyphs) into the
;     unused upper half of the set (codes 128-159 and 160-254, plus a few low codes).
;     The preview then just uses those character codes -- bold_glyph()/ital_glyph() map a
;     letter to its bold/italic code.
;   * LINE CLASSIFICATION: line_kind() decides what a source line is (blank, fence,
;     # heading, setext heading, rule, list item, table, [TOC], paragraph). eff() first
;     strips any leading '>' block-quote markers. The same predicates (atx_s, hr_s,
;     list_s ...) drive both the editor colouring (hl_md) and the preview renderer.
;   * PREVIEW: pv_render() walks the document once and turns it into finished screen
;     rows (80 characters + 80 colours each) which are stored in banked RAM, 51 rows per
;     8 KB bank, in the banks above the changed pages (the cache gives way, see pv_setup). Text is built word by word (out_glyph / wflush) so words
;     wrap; tables are measured first so columns can be sized and shrunk to fit. The
;     viewer (preview_mode) then just copies rows to the screen, so scrolling is instant.
;   * UNDO: one level, a copy of the page table; pages are copied only when first edited.
;
; CODE MAP (top to bottom)
;   configuration & state -> helpers -> keyboard & VERA -> fonts -> buffer & lines -> undo
;   -> character & line classification -> inline markup -> preview renderer -> drawing
;   helpers & dialogs -> preview viewer -> editor colouring & drawing -> cursor movement
;   -> file I/O -> editing commands -> key dispatch (edit_key), editor() and start()
;
; NOTES FOR READERS NEW TO PROG8
;   * `iso:"text"` / `iso:'c'` are ASCII literals; plain "text" would be PETSCII. A "\n" in
;     a Prog8 string is a carriage return (13), which is why insert_str() converts it.
;   * `@(addr)` reads or writes one byte; `peekw/pokew` do 16-bit words. Arrays are limited
;     to 256 elements, so big buffers are raw RAM slabs from memory().
;   * Subroutine variables are static (no recursion). Results that C would return through
;     pointers are left in globals instead (eff -> es/en/eq, atx_s -> atx_lvl/atx_off,
;     link_at -> lk_rb/lk_rp, list_s -> L_ind/L_mk/L_mlen/L_txt/L_ord).
;
; Build:  make         Run:  make run     (x16emu)      Try DEMO.MD: Ctrl-O, DEMO.MD, Ctrl-P

%import syslib
%zeropage basicsafe

main {
    ; ---------------------------------------------------------------
    ; configuration
    ; ---------------------------------------------------------------
    const uword PG    = 1024          ; most bytes in one document page (a frame: 8 per 8K bank)
    const uword MAXLN = 700           ; longest line (a page must be able to hold it)
    const ubyte LPP   = 128           ; most lines in one page
    const uword NMAX  = 4096          ; most pages (page numbers 0..NMAX-1)
    const uword NIL   = $ffff
    const uword MAXLINES = 65000
    const uword FILL  = 880           ; the loader starts a new page when one is this full
    ; banks 1-10 hold the page tables (see "paged document store"); each has a table at $a000 and one at $b000
    const ubyte B_NXL = 1             ; next page, low byte (working / snapshot copy at +0 / +$1000)
    const ubyte B_NXH = 2             ; next page, high byte
    const ubyte B_NL  = 3             ; lines in the page (two copies)
    const ubyte B_FL  = 4             ; $a000: shared with the undo snapshot?  $b000: file offset bits 16-23
    const ubyte B_FO  = 5             ; file offset where the page starts, bits 0-15
    const ubyte B_FLN = 6             ; bytes the page takes in the file (NIL: not in the file)
    const ubyte B_FR  = 7             ; frame holding the page (NIL: none)
    const ubyte B_BL  = 8             ; bytes in the page
    const ubyte B_FREE = 9            ; stack of free page numbers
    const ubyte B_FRM = 10            ; per frame: owner page, state ($a800)
    const ubyte DOC_BANK0 = 11        ; frames (1 KB each, 8 per bank) start at bank 11
    const ubyte FR_FREE  = 0          ; frame states
    const ubyte FR_CLEAN = 1          ;   unchanged copy of the page's bytes in the file
    const ubyte FR_ONLY  = 2          ;   the page's only copy
    const ubyte BKLFN = 5             ; logical file / channel the backing file is read on
    const uword RAWBUF = $b800        ; raw file bytes, read in pieces of RAWLEN: in bank B_FRM,
    const ubyte RAWLEN = 255          ;   which has room for them at $b800-$bfff
    const ubyte FNLEN = 40
    const ubyte DEVICE = 8
    const ubyte SW    = 80            ; widest text screen
    const ubyte MAXH  = 100           ; headings tracked for the TOC
    const ubyte MAXC  = 8             ; table columns
    const uword CLSN  = 240           ; chars coloured per editor line
    const ubyte PV_PER_BANK = 51      ; preview rows (2*80 bytes) per 8K bank

    const ubyte NL  = 10
    const ubyte TAB = 9
    const ubyte SP  = 32

    ; keys (ISO mode)
    const ubyte K_DOWN  = $11
    const ubyte K_UP    = $91
    const ubyte K_LEFT  = $9d
    const ubyte K_RIGHT = $1d
    const ubyte K_HOME  = $13
    const ubyte K_END   = $04
    const ubyte K_BKSP  = $14
    const ubyte K_DEL   = $19
    const ubyte K_ESC   = $1b
    const ubyte K_F1 = $85
    const ubyte K_F2 = $89
    const ubyte K_F3 = $86
    const ubyte K_F4 = $8a
    const ubyte K_F5 = $87
    const ubyte K_F6 = $8b
    const ubyte K_F7 = $88
    const ubyte K_F8 = $8c
    const ubyte CTRL_A = 1
    const ubyte CTRL_B = 2
    const ubyte CTRL_E = 5
    const ubyte CTRL_F = 6
    const ubyte CTRL_G = 7
    const ubyte CTRL_K = 11
    const ubyte CTRL_O = 15
    const ubyte CTRL_P = 16
    const ubyte CTRL_R = 18
    const ubyte CTRL_U = 21
    const ubyte CTRL_W = 23
    const ubyte CTRL_X = 24
    const ubyte CTRL_Z = 26

    ; colours (VERA palette indexes)
    const ubyte C_BG   = 0
    const ubyte C_NORM = 15
    const ubyte C_BOLD = 1
    const ubyte C_ITAL = 14
    const ubyte C_CODE = (11 << 4) | 13         ; inline code
    const ubyte C_CODEBLK = (11 << 4) | 1       ; fenced code
    const ubyte C_LINK = 3
    const ubyte C_IMG  = 10
    const ubyte C_STRIKE = 12
    const ubyte C_MARK = 12                     ; markdown punctuation in editor
    const ubyte C_BUL  = 8
    const ubyte C_QBAR = 5
    const ubyte C_TBL  = 12
    const ubyte C_URL  = 11
    const ubyte C_TOC  = 7
    const ubyte C_LAB  = 13

    ; special glyphs living in otherwise unused charset slots
    const ubyte G_H  = 27
    const ubyte G_V  = 28
    const ubyte G_TL = 29
    const ubyte G_TR = 30
    const ubyte G_BL = 31
    const ubyte G_BR = 127
    const ubyte G_T  = 154
    const ubyte G_B  = 155
    const ubyte G_L  = 156
    const ubyte G_R  = 157
    const ubyte G_X  = 158
    const ubyte G_BUL = 159

    ; Heading colour by level (index 1-6; index 0 is the normal text colour)
    ubyte[7] hcol = [C_NORM, 7, 3, 13, 14, 10, 12]

    ; line kinds
    const ubyte LK_BLANK  = 0
    const ubyte LK_FENCE  = 1
    const ubyte LK_ATX    = 2
    const ubyte LK_SETEXT = 3
    const ubyte LK_HR     = 4
    const ubyte LK_LIST   = 5
    const ubyte LK_TABLE  = 6
    const ubyte LK_TOCM   = 7
    const ubyte LK_PARA   = 8

    ; ---------------------------------------------------------------
    ; state
    ; ---------------------------------------------------------------
    ; The two page windows and their line-start tables are raw RAM slabs (see "paged document store").
    uword pbuf0 = memory("pbuf0", PG + 4, 0)
    uword pbuf1 = memory("pbuf1", PG + 4, 0)
    uword pls0  = $0400               ; (these, cls, msg, rline, iobuf2 and dstat are in "golden RAM",
    uword pls1  = $0506               ;  $0400-$07ff, because main RAM is full)

    uword[2] s_buf            ; slot k: window address
    uword[2] s_ls             ;   line-start table address
    uword[2] s_pg             ;   page index held ($ffff = none)
    uword[2] s_fl             ;   its first line number
    uword[2] s_nl             ;   number of lines (0 = slot empty)
    uword[2] s_bl             ;   bytes used
    ubyte[2] s_dirty          ;   changed since it was loaded?
    ubyte f_slot              ; result of fetch(): slot
    uword f_li                ;   and line index within it
    ubyte lastused
    uword nbanks              ; RAM banks in this machine
    uword nfrm                ; frames in this machine
    uword frlim               ; frames in use now (the preview borrows the upper ones)
    uword fhand               ; where getframe() looks for a frame to drop next
    uword nfree               ; free page numbers
    uword nhw                 ; page numbers in use are below this
    uword head                ; first page of the working chain
    ubyte[41] bkname          ; the backing file: unchanged pages are read from it ("" = none)
    bool bk_isopen
    long bk_pos               ; where the next read from it starts
    ubyte cv_prev             ; file-byte converter state (see cv_byte)
    uword cv_cl
    bool cv_scan
    bool cv_wrap
    uword dec_dst
    uword dec_o
    uword dec_max
    uword snap_head
    uword snap_nlines
    uword nlines              ; lines in the document
    ubyte tsel                ; which table copy is the working one
    uword wo                  ; its offset in the NEXT / NL banks
    uword so                  ; offset of the snapshot copy
    uword sm_cx
    uword sm_cy
    uword fc_l
    bool fc_f
    ubyte pv_lo               ; first bank used by the preview rows (above every document page)
    uword pvmax               ; preview rows that fit
    uword cy
    uword cx
    uword want
    uword top

    ubyte scrw
    ubyte scrh
    ubyte textrows
    ubyte pw
    uword vbase
    uword vstride

    bool modified
    bool truncated
    bool quit
    bool warned
    bool typing
    bool redraw_all
    uword prev_cy
    ubyte[41] fname
    &ubyte[80] msg = $0700
    ubyte[32] lastsearch

    bool uvalid

    &ubyte[240] cls = $060c   ; editor colours per character (in golden RAM, see pls0)
    &ubyte[52] iobuf2 = $07a4
    &ubyte[40] dstat = $07d8

    ; headings
    uword[100] hl            ; source line
    ubyte[100] hlv           ; level 1..6
    uword[100] hvis          ; preview row
    ubyte hn
    ubyte kind_lvl           ; set by line_kind(): heading level

    ; "effective line": a source line with block-quote markers removed
    uword es
    uword en
    ubyte eq

    ; list parse results
    uword L_ind
    uword L_mk
    uword L_mlen
    uword L_txt
    bool L_ord

    ; atx / link results
    ubyte atx_lvl
    uword atx_off
    uword lk_rb
    uword lk_rp

    ubyte[84] sline
    ubyte[34] rbuf
    &ubyte[84] rline = $0750
    ubyte[1] chbuf

    ; ---------------------------------------------------------------
    ; small helpers
    ; ---------------------------------------------------------------
    ; Length of a NUL-terminated string (max 255).
    sub slen(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
    }

    ; Copy a NUL-terminated string, at most maxn characters, always NUL-terminating dst.
    sub copystr(uword dst, uword src, ubyte maxn) {
        ubyte n = 0
        while @(src + n) != 0 and n < maxn {
            @(dst + n) = @(src + n)
            n++
        }
        @(dst + n) = 0
    }

    ; Append src to the NUL-terminated string dst.
    sub appendstr(uword dst, uword src) {
        ubyte n = slen(dst)
        ubyte i = 0
        while @(src + i) != 0 {
            @(dst + n) = @(src + i)
            n++
            i++
        }
        @(dst + n) = 0
    }

    ; Append string src to the buffer dst at offset d; returns the new offset.
    ; (bcat/bnum build the status lines without needing string functions.)
    sub bcat(uword dst, ubyte d, uword src) -> ubyte {
        while @(src) != 0 {
            @(dst + d) = @(src)
            d++
            src++
        }
        return d
    }

    ; Append the decimal number v to the buffer dst at offset d; returns the new offset.
    sub bnum(uword dst, ubyte d, uword v) -> ubyte {
        ubyte[6] tmp
        ubyte t = 0
        repeat {
            tmp[t] = lsb(v % 10) + '0'
            t++
            v /= 10
            if v == 0
                break
        }
        while t != 0 {
            t--
            @(dst + d) = tmp[t]
            d++
        }
        return d
    }

    ; True if n bytes at a and b are identical.
    sub memeq(uword a, uword b, uword n) -> bool {
        uword i = 0
        while i < n {
            if @(a + i) != @(b + i)
                return false
            i++
        }
        return true
    }

    ; True if character c occurs in the first n bytes at s (like C's memchr).
    sub has_char(uword s, uword n, ubyte c) -> bool {
        uword i = 0
        while i < n {
            if @(s + i) == c
                return true
            i++
        }
        return false
    }

    ; Set the message shown on the bottom line (truncated to 79 characters).
    sub setmsg(uword s) {
        copystr(&msg, s, 79)
    }

    ; ---------------------------------------------------------------
    ; keyboard / VERA
    ; ---------------------------------------------------------------
    ; Wait for a key and return it (ISO/ASCII; cursor keys and F-keys use the KERNAL codes).
    ; The line below marked SELFTEST-HOOK (a comment) is swapped in by runtest.sh to feed scripted keys.
    sub getkey() -> ubyte {
        ubyte k
        ;@SELFTEST-HOOK
        repeat {
            k = cbm.GETIN2()
            if k != 0
                break
        }
        return k
    }

    ; Point VERA data port 0 at text-map cell (x,y) with auto-increment 1, so successive
    ; writes fill: char, colour, char, colour ... Colour byte = background<<4 | foreground.
    sub vera_at(ubyte x, ubyte y) {
        cx16.VERA_CTRL &= $fe
        cx16.VERA_ADDR = vbase + (y as uword) * vstride + (x as uword) * 2
        cx16.VERA_ADDR_H = $11
    }

    ; Write one character + colour at (x,y).
    sub put_cell(ubyte x, ubyte y, ubyte ch, ubyte col) {
        vera_at(x, y)
        cx16.VERA_DATA0 = ch
        cx16.VERA_DATA0 = col
    }

    ; Read the screen size and find VERA's text map (layer 1): bytes per map row
    ; (vstride) and the map's base address (vbase). pw is the preview width (max 80).
    sub init_screen() {
        ubyte m
        scrw, scrh = cbm.SCREEN()
        textrows = scrh - 2
        if scrw > SW
            pw = SW
        else
            pw = scrw
        cx16.VERA_CTRL &= $fe
        m = cx16.VERA_L1_CONFIG
        when (m >> 4) & 3 {
            0 -> vstride = 64
            1 -> vstride = 128
            2 -> vstride = 256
            else -> vstride = 512
        }
        vbase = ((cx16.VERA_L1_MAPBASE & $7f) as uword) << 9
    }

    ; Fill the whole screen with blanks.
    sub clear_screen() {
        ubyte y = 0
        ubyte x
        while y < scrh {
            vera_at(0, y)
            x = 0
            while x < scrw {
                cx16.VERA_DATA0 = SP
                cx16.VERA_DATA0 = (C_BG << 4) | C_NORM
                x++
            }
            y++
        }
    }

    ; ---------------------------------------------------------------
    ; fonts: bold, italic and box-drawing glyphs built from the ISO set
    ; ---------------------------------------------------------------
    uword tilebase
    ubyte[8] gg
    ubyte[8] hh

    ; Font helpers: point VERA's data port at the 8-byte glyph for character code c
    ; (tilebase is where layer 1's character set lives).
    sub gl_addr(ubyte c) {
        cx16.VERA_CTRL &= $fe
        cx16.VERA_ADDR = tilebase + (c as uword) * 8
        cx16.VERA_ADDR_H = $11
    }

    ; Read the 8 bytes of glyph c into gg.
    sub gl_read(ubyte c) {
        ubyte i
        gl_addr(c)
        for i in 0 to 7
            gg[i] = cx16.VERA_DATA0
    }

    ; Write the 8 bytes in hh as glyph c.
    sub gl_write(ubyte c) {
        ubyte i
        gl_addr(c)
        for i in 0 to 7
            cx16.VERA_DATA0 = hh[i]
    }

    ; Build a box-drawing glyph in character code idx. u/d/l/r say which of the four
    ; arms (up, down, left, right) it has; the line is 1 pixel wide through the centre.
    sub box_glyph(ubyte idx, ubyte u, ubyte d, ubyte l, ubyte r) {
        ubyte i
        for i in 0 to 7
            hh[i] = 0
        if u != 0 {
            for i in 0 to 3
                hh[i] |= $10
        }
        if d != 0 {
            for i in 3 to 7
                hh[i] |= $10
        }
        if l != 0
            hh[3] |= $f0
        if r != 0
            hh[3] |= $1f
        gl_write(idx)
    }

    ; Character code that displays c in bold (printable chars are stored +128).
    sub bold_glyph(ubyte c) -> ubyte {
        if c > 32 and c < 127
            return c + 128
        return c
    }

    ; Character code that displays letter c in italic (A-Z -> 1-26, a-z -> 128-153).
    sub ital_glyph(ubyte c) -> ubyte {
        if c >= iso:'A' and c <= iso:'Z'
            return c - iso:'A' + 1
        if c >= iso:'a' and c <= iso:'z'
            return c - iso:'a' + 128
        return c
    }

    ; Create the bold and italic faces and the table/bullet glyphs (see header).
    ; Bold = each row ORed with itself shifted right 1 pixel. Italic = the top half of
    ; each letter shifted right 1 pixel (a cheap slant).
    sub build_fonts() {
        ubyte c
        ubyte i
        tilebase = ((cx16.VERA_L1_TILEBASE & $fc) as uword) << 9
        for c in 33 to 126 {
            gl_read(c)
            for i in 0 to 7
                hh[i] = gg[i] | (gg[i] >> 1)
            gl_write(bold_glyph(c))
            if (c >= iso:'A' and c <= iso:'Z') or (c >= iso:'a' and c <= iso:'z') {
                for i in 0 to 7 {
                    if i < 4
                        hh[i] = gg[i] >> 1
                    else
                        hh[i] = gg[i]
                }
                gl_write(ital_glyph(c))
            }
        }
        box_glyph(G_H, 0, 0, 1, 1)
        box_glyph(G_V, 1, 1, 0, 0)
        box_glyph(G_TL, 0, 1, 0, 1)
        box_glyph(G_TR, 0, 1, 1, 0)
        box_glyph(G_BL, 1, 0, 0, 1)
        box_glyph(G_BR, 1, 0, 1, 0)
        box_glyph(G_T, 0, 1, 1, 1)
        box_glyph(G_B, 1, 0, 1, 1)
        box_glyph(G_L, 1, 1, 0, 1)
        box_glyph(G_R, 1, 1, 1, 0)
        box_glyph(G_X, 1, 1, 1, 1)
        hh[0] = 0
        hh[1] = 0
        hh[2] = $18
        hh[3] = $3c
        hh[4] = $3c
        hh[5] = $18
        hh[6] = 0
        hh[7] = 0
        gl_write(G_BUL)
    }

    ; ---------------------------------------------------------------
    ; paged document store
    ; ---------------------------------------------------------------
    ; The document does NOT live in main RAM. It is a chain of PAGES (a page is a run of whole
    ; lines, at most PG bytes and LPP lines). Main RAM only holds two page-sized WINDOWS ("slots")
    ; caching the pages being looked at or edited. Lines are addressed by line number everywhere:
    ;     lp(l)       pointer to the text of line l (valid until another page has to be loaded)
    ;     linelen(l)  its length
    ; fetch(l) makes the page that holds line l resident (writing the slot it replaces back first
    ; if that was changed). Two slots are enough because the code never needs more than two
    ; neighbouring lines at once (line_kind looks at l and l+1).
    ;
    ; WHERE A PAGE'S TEXT IS. Loading a file does not read it into memory: load_file() only scans
    ; it once and records, for every page, its line count and where its bytes are in the file
    ; (the "backing file", bkname). The text is read from the file when a page is first needed
    ; (pg_read) and kept in a FRAME, a 2 KB slot of banked RAM. A frame is either
    ;     FR_CLEAN  an unchanged copy of the file's bytes: it can be dropped at any time and read
    ;               again later, so the cache never fills up while just moving around
    ;     FR_ONLY   the page was changed (or is new): the frame is its only copy
    ; So files much larger than memory can be viewed and edited; only CHANGED pages take RAM.
    ; Saving writes the whole document and then makes the saved file the backing file, which
    ; turns every frame back into a clean copy (see save_file / rebase).
    ;
    ; A page is identified by its number g (a node of a linked list). For every g, banked RAM holds
    ; the next page in document order (NEXT) and its line count (NL), in two copies: "working"
    ; and "snapshot". Undo is copy-on-write on whole pages: snap() copies those arrays and marks
    ; every page shared; the first edit to a shared page moves the working chain to a fresh copy.
    ; Ctrl-Z just swaps which copy is the working one.
    ;
    ; All edits go through splice() (replace some bytes of a line by other bytes); ed_insert,
    ; del_chars, del_line and join_next are thin wrappers.

    ; --- tables in banked RAM. Each bank holds two NMAX-entry byte tables: one at $a000 + g, one at
    ; $b000 + g. A 16-bit table keeps its low bytes in the first and its high bytes in the second. ---
    ; (assembly, because these are called from everywhere: arguments come in registers)
    ; Byte o (0-$1fff) of bank b.
    asmsub bget(ubyte b @A, uword o @R0) -> ubyte @A {
        %asm {{
            sta  $00
            lda  cx16.r0
            sta  P8ZP_SCRATCH_W1
            lda  cx16.r0+1
            ora  #$a0
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            stz  $00
            rts
        }}
    }

    asmsub bset(ubyte b @A, uword o @R0, ubyte v @Y) {
        %asm {{
            sta  $00
            lda  cx16.r0
            sta  P8ZP_SCRATCH_W1
            lda  cx16.r0+1
            ora  #$a0
            sta  P8ZP_SCRATCH_W1+1
            tya
            sta  (P8ZP_SCRATCH_W1)
            stz  $00
            rts
        }}
    }

    ; Entry g (0-$fff) of the 16-bit table in bank b.
    asmsub wget(ubyte b @A, uword g @R0) -> uword @AY {
        %asm {{
            sta  $00
            lda  cx16.r0
            sta  P8ZP_SCRATCH_W1
            lda  cx16.r0+1
            ora  #$a0
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            pha
            lda  P8ZP_SCRATCH_W1+1
            ora  #$10
            sta  P8ZP_SCRATCH_W1+1
            lda  (P8ZP_SCRATCH_W1)
            tay
            pla
            stz  $00
            rts
        }}
    }

    asmsub wset(ubyte b @A, uword g @R0, uword v @R1) {
        %asm {{
            sta  $00
            lda  cx16.r0
            sta  P8ZP_SCRATCH_W1
            lda  cx16.r0+1
            ora  #$a0
            sta  P8ZP_SCRATCH_W1+1
            lda  cx16.r1
            sta  (P8ZP_SCRATCH_W1)
            lda  P8ZP_SCRATCH_W1+1
            ora  #$10
            sta  P8ZP_SCRATCH_W1+1
            lda  cx16.r1+1
            sta  (P8ZP_SCRATCH_W1)
            stz  $00
            rts
        }}
    }

    ; NEXT and NL: table copy 0 is at offset 0, copy 1 at $1000 (wo = working, so = snapshot).
    sub nxo(uword o) -> uword {
        ubyte h = bget(B_NXH, o)
        return mkword(h, bget(B_NXL, o))
    }

    ; Next page after g in the working chain / in the snapshot chain.
    sub nx(uword g) -> uword {
        return nxo(g + wo)
    }

    sub snx(uword g) -> uword {
        return nxo(g + so)
    }

    sub setnx(uword g, uword v) {
        g += wo
        bset(B_NXL, g, lsb(v))
        bset(B_NXH, g, msb(v))
    }

    ; Number of lines in page g.
    sub nlc(uword g) -> ubyte {
        return bget(B_NL, g + wo)
    }

    sub setnl(uword g, ubyte n) {
        bset(B_NL, g + wo, n)
    }

    ; Choose which of the two table copies is the working one.
    sub set_tsel(ubyte t) {
        tsel = t
        wo = 0
        so = $1000
        if t != 0 {
            wo = $1000
            so = 0
        }
    }

    ; Where page g starts in the backing file (24 bits: two bytes in bank B_FO, one in B_FL).
    ubyte[4] lbuf
    sub foff(uword g) -> long {
        pokew(&lbuf, wget(B_FO, g))
        lbuf[2] = bget(B_FL, g + $1000)
        lbuf[3] = 0
        return peekl(&lbuf)
    }

    sub set_foff(uword g, long v) {
        pokel(&lbuf, v)
        wset(B_FO, g, peekw(&lbuf))
        bset(B_FL, g + $1000, lbuf[2])
    }

    ; Free page numbers are kept on a stack. A new page has no frame and nothing in the file.
    sub alloc_pg() -> uword {
        uword g
        nfree--
        g = wget(B_FREE, nfree)
        if g >= nhw
            nhw = g + 1
        bset(B_FL, g, 0)
        wset(B_FR, g, NIL)
        wset(B_FLN, g, NIL)
        wset(B_BL, g, 0)
        return g
    }

    sub free_pg(uword g) {
        uword f = wget(B_FR, g)
        if f != NIL
            set_fstate(f, FR_FREE)
        wset(B_FREE, nfree, g)
        nfree++
    }

    ; The page before g in the working chain.
    sub pred_of(uword g) -> uword {
        uword p = head
        uword n
        while p != NIL {
            n = nx(p)
            if n == g
                return p
            p = n
        }
        return NIL
    }

    ; Replace page g by g2 in the working chain (g2 takes over g's place and line count).
    sub relink(uword g, uword g2) {
        uword p = pred_of(g)
        setnx(g2, nx(g))
        setnl(g2, nlc(g))
        if p == NIL
            head = g2
        else
            setnx(p, g2)
    }

    ; --- frames: frame f is 1 KB at $a000 + (f%8)*1024 in bank DOC_BANK0 + f/8. Bank B_FRM holds
    ; each frame's owner page ($a000/$b000 + f) and state ($a800 + f). ---
    sub fstate(uword f) -> ubyte {
        return bget(B_FRM, $0800 + f)
    }

    sub set_fstate(uword f, ubyte s) {
        bset(B_FRM, $0800 + f, s)
    }

    ; Select frame f's bank and return its address.
    sub fr_at(uword f) -> uword {
        cx16.rambank(DOC_BANK0 + lsb(f >> 3))
        return $a000 + ((f & 7) << 10)
    }

    ; Give frame f to page g.
    sub claim(uword f, uword g, ubyte s) {
        wset(B_FRM, f, g)
        set_fstate(f, s)
        wset(B_FR, g, f)
    }

    ; A frame for a page: a free one, or else one holding a clean copy, which is simply dropped
    ; (round robin, so the pages read most recently are dropped last). NIL if every frame holds
    ; an only copy.
    sub getframe() -> uword {
        uword f = 0
        cx16.rambank(B_FRM)
        while f < frlim {
            if @($a800 + f) == FR_FREE {
                cx16.rambank(0)
                return f
            }
            f++
        }
        cx16.rambank(0)
        repeat frlim {
            fhand++
            if fhand >= frlim
                fhand = 0
            if fstate(fhand) == FR_CLEAN {
                wset(B_FR, wget(B_FRM, fhand), NIL)
                return fhand
            }
        }
        return NIL
    }

    ; Frames that could take a changed page (free or only a clean copy).
    sub avail() -> uword {
        uword f = 0
        uword n = 0
        cx16.rambank(B_FRM)
        while f < frlim {
            if @($a800 + f) != FR_ONLY
                n++
            f++
        }
        cx16.rambank(0)
        return n
    }

    ; Copy page g into dst (a window): from its frame, or else from the file, keeping a clean copy
    ; in a frame if one can be had.
    sub pg_read(uword g, uword dst) {
        uword f = wget(B_FR, g)
        if f == NIL {
            disk_page(g, dst)
            f = getframe()
            if f == NIL
                return
            claim(f, g, FR_CLEAN)
            sys.memcopy(dst, fr_at(f), PG)
        } else
            sys.memcopy(fr_at(f), dst, PG)
        cx16.rambank(0)
    }

    ; Store n bytes from src as the new text of page g: from now on its frame is its only copy.
    sub pg_write(uword g, uword src, uword n) {
        uword f = wget(B_FR, g)
        if f == NIL {
            f = getframe()
            if f == NIL {
                setmsg(iso:"Out of memory: a change was lost!")
                return
            }
        }
        claim(f, g, FR_ONLY)
        wset(B_FLN, g, NIL)
        wset(B_BL, g, n)
        if n != 0
            sys.memcopy(src, fr_at(f), n)
        cx16.rambank(0)
    }

    ; --- the backing file: kept open on channel BKLFN while pages are read from it ---
    sub bk_close() {
        if bk_isopen {
            cbm.CLOSE(BKLFN)
            bk_isopen = false
        }
    }

    sub bk_open() {
        if bk_isopen
            return
        copystr(&iobuf2, &bkname, 44)
        appendstr(&iobuf2, iso:",s,r")
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(BKLFN, DEVICE, BKLFN)
        void cbm.OPEN()
        bk_isopen = true
        bk_pos = 0
    }

    ; Position the backing file at byte pos (CMDR-DOS "P" command on the command channel). Pages are
    ; in the file in document order, so moving forward usually reads on where the last read ended:
    ; then no seek is needed.
    ubyte[6] pcmd = [$50, BKLFN, 0, 0, 0, 0]
    sub bk_seek(long pos) {
        bk_open()
        if pos == bk_pos
            return
        bk_pos = pos
        pokel(&pcmd + 2, pos)
        cbm.SETNAM(6, &pcmd)
        cbm.SETLFS(15, DEVICE, 15)
        void cbm.OPEN()
        cbm.CLOSE(15)
    }

    ; Read up to n bytes of the backing file into dst; returns how many were read. At the end of
    ; the file (or on an error) the file is closed, because a seek no longer works after that;
    ; the next bk_seek opens it again. (Reading pages back needs CMDR-DOS, the X16's SD card / host
    ; file system: it has the "P" command and the MACPTR / MCIOUT block transfers used here.)
    sub bk_read(uword dst, ubyte n) -> ubyte {
        uword got = 0
        bool failed
        if bk_isopen {
            void cbm.CHKIN(BKLFN)
            cx16.rambank(B_FRM)                         ; (for RAWBUF)
            failed, got = cx16.MACPTR(n, dst, false)   ; fails if the file could not be opened
            cx16.rambank(0)
            if failed
                got = 0
            bk_pos += got
            n = cbm.READST()
            cbm.CLRCHN()
            if n != 0 or got == 0
                bk_close()
        }
        return lsb(got)
    }

    ; --- converting file bytes to document bytes: CR and CRLF become LF, NULs are dropped and lines
    ; longer than MAXLN are broken. The same converter measures the file when it is loaded
    ; (cv_scan: only counting, see ld_note) and decodes a single page later (writing to dec_dst),
    ; so a page read back always matches what was counted. A page starts at the file byte that
    ; produced its first character, with the converter state reset (start of a line). ---
    sub cv_byte(ubyte c) {
        ubyte raw = c
        if c == 13
            c = NL
        else if c == NL and cv_prev == 13 {
            cv_prev = raw
            return
        }
        cv_prev = raw
        if c == 0
            return
        if c != NL and cv_cl >= MAXLN {
            cv_out(NL)
            cv_wrap = true
        }
        cv_out(c)
    }

    sub cv_out(ubyte c) {
        if cv_scan
            ld_note(c)
        else if dec_o < dec_max {
            @(dec_dst + dec_o) = c
            dec_o++
        }
        if c == NL
            cv_cl = 0
        else
            cv_cl++
    }

    ; Fast path of the converter (assembly; it runs for nearly every byte of a file): handles
    ; RAWBUF[i..cv_n) for as long as the bytes are plain characters inside a line (not CR, LF or
    ; NUL, not the first character of a line, not at the line limit MAXLN = 700, and the page is
    ; not full: FILL = 880 when measuring, dec_max when decoding). Returns where it stopped;
    ; cv_byte() takes the byte there.
    asmsub cv_fast(ubyte i @Y) clobbers(A, X) -> ubyte @Y {
        %asm {{
            lda  p8b_main.p8v_dec_dst
            clc
            adc  p8b_main.p8v_dec_o
            sta  P8ZP_SCRATCH_W2
            lda  p8b_main.p8v_dec_dst+1
            adc  p8b_main.p8v_dec_o+1
            sta  P8ZP_SCRATCH_W2+1
            lda  #10                    ; bank B_FRM holds RAWBUF ($b800)
            sta  $00
_loop       cpy  p8b_main.p8v_cv_n
            bcs  _done
            lda  p8b_main.p8v_cv_cl+1   ; 0 < cv_cl < 700 ?
            bne  _clhi
            lda  p8b_main.p8v_cv_cl
            beq  _done
            bra  _clok
_clhi       cmp  #>700
            bcc  _clok
            bne  _done
            lda  p8b_main.p8v_cv_cl
            cmp  #<700
            bcs  _done
_clok       lda  $b800,y
            cmp  #14
            bcs  _plain
            cmp  #13
            beq  _done
            cmp  #10
            beq  _done
            cmp  #0
            beq  _done
_plain      ldx  p8b_main.p8v_cv_scan
            beq  _dec
            ldx  p8b_main.p8v_ld_o+1    ; measuring: ld_o < 880 ?
            cpx  #>880
            bcc  _cnt
            bne  _done
            ldx  p8b_main.p8v_ld_o
            cpx  #<880
            bcs  _done
_cnt        inc  p8b_main.p8v_ld_o
            bne  _next
            inc  p8b_main.p8v_ld_o+1
            bra  _next
_dec        ldx  p8b_main.p8v_dec_o+1   ; decoding: dec_o < dec_max ?
            cpx  p8b_main.p8v_dec_max+1
            bcc  _put
            bne  _done
            ldx  p8b_main.p8v_dec_o
            cpx  p8b_main.p8v_dec_max
            bcs  _done
_put        sta  (P8ZP_SCRATCH_W2)
            inc  P8ZP_SCRATCH_W2
            bne  _inco
            inc  P8ZP_SCRATCH_W2+1
_inco       inc  p8b_main.p8v_dec_o
            bne  _next
            inc  p8b_main.p8v_dec_o+1
_next       sta  p8b_main.p8v_cv_prev
            inc  p8b_main.p8v_cv_cl
            bne  _iny
            inc  p8b_main.p8v_cv_cl+1
_iny        iny
            bra  _loop
_done       stz  $00
            rts
        }}
    }

    ; Read page g from the backing file into dst. If the file no longer matches (changed behind our
    ; back) the page is padded / cut to its recorded size, so the line bookkeeping stays sane.
    sub disk_page(uword g, uword dst) {
        uword left = wget(B_FLN, g)
        ubyte n
        ubyte i
        dec_dst = dst
        dec_o = 0
        dec_max = wget(B_BL, g)
        cv_scan = false
        cv_cl = 0
        cv_prev = 0
        bk_seek(foff(g))
        while left != 0 {
            n = RAWLEN
            if left < RAWLEN
                n = lsb(left)
            n = bk_read(RAWBUF, n)
            if n == 0
                break
            left -= n
            cv_n = n
            i = 0
            while i < n {
                i = cv_fast(i)
                if i < n {
                    cv_byte(bget(B_FRM, RAWBUF - $a000 + i))
                    i++
                }
            }
        }
        while dec_o < dec_max {
            @(dst + dec_o) = NL                   ; also adds a missing newline at the end of the file
            dec_o++
        }
        @(dst + dec_max - 1) = NL
    }

    ; --- the two resident slots ---
    ; Line-start offset of line index i within slot k (entry nl is the end marker).
    sub lso(ubyte k, uword i) -> uword {
        return peekw(s_ls[k] + (i << 1))
    }

    ; Rebuild slot k's line-start table from its bytes (nl lines); also sets s_bl.
    sub slot_scan(ubyte k, uword nl) {
        uword b = s_buf[k]
        uword t = s_ls[k]
        uword i = 0
        uword j = 0
        pokew(t, 0)
        while j < nl {
            if @(b + i) == NL {
                j++
                pokew(t + (j << 1), i + 1)
            }
            i++
        }
        s_bl[k] = i
    }

    ; Write slot k back to its page if it was changed.
    sub slot_flush(ubyte k) {
        if s_dirty[k] == 0
            return
        pg_write(s_pg[k], s_buf[k], s_bl[k])
        s_dirty[k] = 0
    }

    sub flush_all() {
        slot_flush(0)
        slot_flush(1)
    }

    ; Forget what is cached (after flushing).
    sub slots_drop() {
        flush_all()
        s_nl[0] = 0
        s_nl[1] = 0
        s_pg[0] = NIL
        s_pg[1] = NIL
    }

    ; Load page g (whose first line is number fl) into slot k.
    sub slot_load(ubyte k, uword g, uword fl) {
        uword nl
        slot_flush(k)
        nl = nlc(g)
        pg_read(g, s_buf[k])
        s_pg[k] = g
        s_fl[k] = fl
        s_nl[k] = nl
        slot_scan(k, nl)
    }

    ; Make the page holding line l resident. Result: f_slot (which slot) and f_li (line index in it).
    ; A miss replaces the slot that was NOT used last, so the line just used stays valid.
    sub fetch(uword l) {
        ubyte k
        uword g
        uword fl
        uword n
        uword nn
        for k in 0 to 1 {
            if l - s_fl[k] < s_nl[k] {
                f_slot = k
                f_li = l - s_fl[k]
                lastused = k
                return
            }
        }
        ; walk the chain, starting from a resident page that is not after l
        g = head
        fl = 0
        for k in 0 to 1 {
            if s_nl[k] != 0 and s_fl[k] <= l and s_fl[k] >= fl {
                g = s_pg[k]
                fl = s_fl[k]
            }
        }
        repeat {
            n = nlc(g)
            if l - fl < n
                break
            nn = nx(g)
            if nn == NIL
                break
            fl += n
            g = nn
        }
        k = lastused ^ 1
        slot_load(k, g, fl)
        f_slot = k
        f_li = l - fl
        lastused = k
    }

    ; Pointer to the text of line l.
    sub lp(uword l) -> uword {
        fetch(l)
        return s_buf[f_slot] + lso(f_slot, f_li)
    }

    ; Number of characters in line l (not counting its newline).
    sub linelen(uword l) -> uword {
        fetch(l)
        return lso(f_slot, f_li + 1) - lso(f_slot, f_li) - 1
    }

    ; Set up the page pool: all pages and frames free, no document, no backing file.
    sub pool_reset() {
        uword i
        bk_close()
        bkname[0] = 0
        nfrm = (nbanks - DOC_BANK0) * 8
        frlim = nfrm
        cx16.rambank(B_FRM)
        sys.memset($a800, 2048, FR_FREE)
        cx16.rambank(B_FREE)
        i = 0
        while i < NMAX {
            @($a000 + i) = lsb(NMAX - 1 - i)
            @($b000 + i) = msb(NMAX - 1 - i)
            i++
        }
        cx16.rambank(0)
        nfree = NMAX
        nhw = 0
        head = NIL
        nlines = 0
        uvalid = false
        set_tsel(0)
        s_dirty[0] = 0
        s_dirty[1] = 0
        slots_drop()
        fc_l = 0
        fc_f = false
    }

    ; Make a one-page document from the n bytes (nl lines) in pbuf0.
    sub single_page(uword n, ubyte nl) {
        uword g = alloc_pg()
        pg_write(g, pbuf0, n)
        setnx(g, NIL)
        setnl(g, nl)
        head = g
        nlines = nl
    }

    ; Reset to an empty document (a single newline).
    sub new_buffer() {
        pool_reset()
        @(pbuf0) = NL
        single_page(1, 1)
        cy = 0
        cx = 0
        want = 0
        top = 0
        modified = false
    }

    ; Before changing the page in slot k: if it is shared with the undo snapshot, move the working
    ; chain to a private copy (the slot's content is flushed into it later); then mark it changed.
    sub mod_begin(ubyte k) {
        uword g = s_pg[k]
        uword g2
        if bget(B_FL, g) != 0 {
            g2 = alloc_pg()
            bset(B_FL, g, 0)
            relink(g, g2)
            s_pg[k] = g2
        }
        s_dirty[k] = 1
    }

    ; Split the page in slot k (already mod_begin'ed) at line index m. The slot keeps the part that
    ; holds the line being edited (f_li): the upper part if keep_upper, else the lower part; the
    ; other part goes to its own page. f_li is updated.
    sub page_split(ubyte k, uword m, bool keep_upper) {
        uword g = s_pg[k]
        uword nl = s_nl[k]
        uword cut = lso(k, m)
        uword tail = s_bl[k] - cut
        uword g2 = alloc_pg()
        setnx(g2, nx(g))
        setnx(g, g2)
        setnl(g, lsb(m))
        setnl(g2, lsb(nl - m))
        if keep_upper {
            pg_write(g, s_buf[k], cut)            ; the lower part stays in page g
            cx16.memory_copy(s_buf[k] + cut, s_buf[k], tail)
            s_pg[k] = g2
            s_fl[k] += m
            s_nl[k] = nl - m
            slot_scan(k, nl - m)
            f_li -= m
        } else {
            pg_write(g2, s_buf[k] + cut, tail)
            s_nl[k] = m
            s_bl[k] = cut
        }
        s_dirty[k] = 1
    }

    ; Make room in slot k's page for `bytes` more bytes and `lines` more lines, splitting the page
    ; if needed. The line being edited is f_li in slot k.
    sub ensure_room(ubyte k, uword bytes, uword lines) -> bool {
        ubyte tries = 0
        uword m
        uword half
        while s_bl[k] + bytes > PG or s_nl[k] + lines > LPP {
            if s_nl[k] < 2 or tries == 3 {
                setmsg(iso:"Page full!")
                return false
            }
            half = s_bl[k] >> 1
            m = 1
            while m < s_nl[k] - 1 and lso(k, m) < half
                m++
            page_split(k, m, f_li >= m)
            tries++
        }
        return true
    }

    ; Fence-state cache: fc_f = are we inside a code fence at the start of line fc_l? Any edit above
    ; the cached line throws it away.
    sub fc_inv(uword l) {
        if l < fc_l {
            fc_l = 0
            fc_f = false
        }
    }

    ; Can we afford an edit? An insertion may need a few fresh pages and frames (copy-on-write,
    ; split); a deletion at most one. Frames run out only when that much has been CHANGED; saving
    ; frees them again. (Deletions need less, so an "insert, then delete" edit cannot stop halfway.)
    sub edit_ok(ubyte need) -> bool {
        if nfree < need or avail() < need {
            setmsg(iso:"Memory full of changes: save (Ctrl-W) to free it")
            return false
        }
        return true
    }

    ; THE editing primitive: in line l, replace ndel bytes starting at column c by the nins bytes at
    ; src (either may be 0; src may contain newlines; deleted bytes must lie in this page, i.e. they
    ; may include the newline that ends the line only if it is not the last line of its page).
    sub splice(uword l, uword c, uword ndel, uword src, uword nins) -> bool {
        ubyte k
        ubyte o
        uword g
        uword pos
        uword add_nl = 0
        uword del_nl = 0
        uword newnl
        uword fk
        uword need
        uword i = 0
        o = 6
        if nins == 0
            o = 2
        if not edit_ok(o)
            return false
        while i < nins {
            if @(src + i) == NL
                add_nl++
            i++
        }
        fetch(l)
        k = f_slot
        if ndel == 0 and add_nl == 0 and nins != 0 and lso(k, f_li + 1) - lso(k, f_li) - 1 + nins > MAXLN {
            setmsg(iso:"Line too long!")
            return false
        }
        if add_nl != 0 and nlines + add_nl > MAXLINES {
            setmsg(iso:"Too many lines!")
            return false
        }
        mod_begin(k)
        if nins > ndel
            need = nins - ndel
        else
            need = 0
        if need != 0 or add_nl != 0 {
            if not ensure_room(k, need, add_nl)
                return false
        }
        pos = lso(k, f_li) + c
        i = pos
        while i < pos + ndel {
            if @(s_buf[k] + i) == NL
                del_nl++
            i++
        }
        i = s_bl[k] - pos - ndel                      ; bytes after the replaced range
        if i != 0
            cx16.memory_copy(s_buf[k] + pos + ndel, s_buf[k] + pos + nins, i)
        if nins != 0
            sys.memcopy(src, s_buf[k] + pos, nins)
        fk = s_fl[k]
        g = s_pg[k]
        newnl = s_nl[k] + add_nl - del_nl
        if newnl == 0 {                               ; the page became empty: drop it
            relink_out(g)
            free_pg(g)
            s_nl[k] = 0
            s_pg[k] = NIL
            s_dirty[k] = 0
        } else {
            s_nl[k] = newnl
            setnl(g, lsb(newnl))
            if add_nl == 0 and del_nl == 0 {          ; same lines: just shift the later line starts
                s_bl[k] += nins - ndel
                i = f_li + 1
                while i <= newnl {
                    pokew(s_ls[k] + (i << 1), lso(k, i) + nins - ndel)
                    i++
                }
            } else
                slot_scan(k, newnl)
        }
        if add_nl != del_nl {
            nlines += add_nl - del_nl
            o = k ^ 1
            if s_nl[o] != 0 and s_fl[o] > fk
                s_fl[o] += add_nl - del_nl
        }
        modified = true
        redraw_all = true
        fc_inv(l)
        return true
    }

    ; Take page g out of the working chain.
    sub relink_out(uword g) {
        uword p = pred_of(g)
        if p == NIL
            head = nx(g)
        else
            setnx(p, nx(g))
    }

    ; Insert n bytes (which may contain newlines) at line l, column c.
    sub ed_insert(uword l, uword c, uword src, uword n) -> bool {
        return splice(l, c, 0, src, n)
    }

    ; Delete n bytes from line l starting at column c (all inside the line).
    sub del_chars(uword l, uword c, uword n) {
        void splice(l, c, n, 0, 0)
    }

    ; Delete the whole of line l including its newline (never the last remaining line).
    sub del_line(uword l) {
        if nlines > 1
            void splice(l, 0, linelen(l) + 1, 0, 0)
    }

    ; Join line l and line l+1 (delete the newline that ends line l). Returns false if the result
    ; would be too long.
    sub join_next(uword l) -> bool {
        ubyte k
        uword n1
        uword n2
        uword src
        if l + 1 >= nlines
            return false
        n1 = linelen(l)
        n2 = linelen(l + 1)
        if n1 + n2 > MAXLN {
            setmsg(iso:"Line too long!")
            return false
        }
        fetch(l)
        k = f_slot
        if f_li + 1 < s_nl[k]
            return splice(l, n1, 1, 0, 0)
        ; l is the last line of its page: put its text in front of line l+1 (next page), then delete
        ; line l. Both pages stay resident (a miss replaces the slot not used last).
        src = s_buf[k] + lso(k, f_li)
        if not splice(l + 1, 0, 0, src, n1)
            return false
        del_line(l)
        return true
    }

    ; ---------------------------------------------------------------
    ; undo (copy-on-write page tables, see the note at the top of the store section)
    ; ---------------------------------------------------------------
    ; Free the pages that only the snapshot uses (not marked shared).
    sub free_snap_only() {
        uword g = snap_head
        uword n
        while g != NIL {
            n = snx(g)
            if bget(B_FL, g) == 0
                free_pg(g)
            g = n
        }
    }

    ; Forget the undo snapshot.
    sub drop_undo() {
        uword g = head
        if uvalid
            free_snap_only()
        while g != NIL {
            bset(B_FL, g, 0)
            g = nx(g)
        }
        uvalid = false
    }

    ; Take an undo snapshot of the current state; called before each change. Pages that only the
    ; previous snapshot still used are freed; every page of the new snapshot is marked shared.
    sub snap() {
        uword g
        flush_all()
        if uvalid
            free_snap_only()
        cx16.rambank(B_NXL)
        cx16.memory_copy($a000 + wo, $a000 + so, nhw)
        cx16.rambank(B_NXH)
        cx16.memory_copy($a000 + wo, $a000 + so, nhw)
        cx16.rambank(B_NL)
        cx16.memory_copy($a000 + wo, $a000 + so, nhw)
        cx16.rambank(0)
        g = head
        while g != NIL {
            bset(B_FL, g, 1)
            g = nx(g)
        }
        snap_head = head
        snap_nlines = nlines
        sm_cx = cx
        sm_cy = cy
        uvalid = true
    }

    ; Ctrl-Z: swap the working tables with the snapshot. The state we leave becomes the snapshot,
    ; so pressing Ctrl-Z again redoes.
    sub do_undo() {
        uword t
        if not uvalid {
            setmsg(iso:"Nothing to undo")
            return
        }
        slots_drop()
        set_tsel(tsel ^ 1)
        t = head
        head = snap_head
        snap_head = t
        t = nlines
        nlines = snap_nlines
        snap_nlines = t
        t = cx
        cx = sm_cx
        sm_cx = t
        t = cy
        cy = sm_cy
        sm_cy = t
        if cy >= nlines
            cy = nlines - 1
        if cx > linelen(cy)
            cx = linelen(cy)
        fc_l = 0
        fc_f = false
        modified = true
        redraw_all = true
        setmsg(iso:"Undo (Ctrl-Z again = redo)")
    }

    ; ---------------------------------------------------------------
    ; character helpers
    ; ---------------------------------------------------------------
    ; Character class helpers.
    sub is_digit(ubyte c) -> bool {
        return c >= '0' and c <= '9'
    }

    sub is_alnum(ubyte c) -> bool {
        return is_digit(c) or (c >= iso:'A' and c <= iso:'Z') or (c >= iso:'a' and c <= iso:'z')
    }

    sub is_punct(ubyte c) -> bool {
        return c > 32 and c < 127 and not is_alnum(c)
    }

    sub is_sp(ubyte c) -> bool {
        return c == SP or c == TAB
    }

    ; ---------------------------------------------------------------
    ; markdown line classification
    ; ---------------------------------------------------------------
    ; True if the n characters at s are all spaces/tabs.
    sub blank_s(uword s, uword n) -> bool {
        while n != 0 {
            if not is_sp(@(s))
                return false
            s++
            n--
        }
        return true
    }

    ; The 'effective line': line l with leading '>' block-quote markers (up to 4, each
    ; optionally preceded by up to 3 spaces) removed. Result: es = start, en = length,
    ; eq = number of quote levels. Everything that classifies a line works on this.
    sub eff(uword l) {
        uword s = lp(l)
        uword n = linelen(l)
        ubyte q = 0
        ubyte sp
        repeat {
            sp = 0
            while n != 0 and @(s) == SP and sp < 3 {
                s++
                n--
                sp++
            }
            if n != 0 and @(s) == iso:'>' and q < 4 {
                q++
                s++
                n--
                if n != 0 and @(s) == SP {
                    s++
                    n--
                }
            } else {
                s -= sp
                n += sp
                break
            }
        }
        es = s
        en = n
        eq = q
    }

    ; Is this a code-fence line (``` or ~~~, up to 3 spaces of indent)?
    sub fence_s(uword s, uword n) -> bool {
        ubyte sp = 0
        ubyte c
        while n != 0 and @(s) == SP and sp < 3 {
            s++
            n--
            sp++
        }
        if n < 3
            return false
        c = @(s)
        return (c == iso:'`' or c == iso:'~') and @(s + 1) == c and @(s + 2) == c
    }

    ; Is this an ATX heading ('#' to '######' followed by a space or end of line)?
    ; If so sets atx_lvl (1-6) and atx_off (offset of the heading text).
    sub atx_s(uword s, uword n) -> bool {
        uword i = 0
        ubyte k = 0
        while i < n and @(s + i) == SP and i < 3
            i++
        while i < n and @(s + i) == iso:'#' and k < 7 {
            i++
            k++
        }
        if k < 1 or k > 6
            return false
        if i < n and @(s + i) != SP
            return false
        while i < n and @(s + i) == SP
            i++
        atx_lvl = k
        atx_off = i
        return true
    }

    ; Is this a horizontal rule: three or more of - * _ (optionally spaced) and nothing else?
    sub hr_s(uword s, uword n) -> bool {
        uword i = 0
        uword cnt = 0
        ubyte c
        while i < n and @(s + i) == SP and i < 3
            i++
        if i >= n
            return false
        c = @(s + i)
        if c != iso:'-' and c != iso:'*' and c != iso:'_'
            return false
        while i < n {
            if @(s + i) == c
                cnt++
            else if @(s + i) != SP
                return false
            i++
        }
        return cnt >= 3
    }

    ; Is this a list item ('- ', '* ', '+ ', or '1. ' / '1) ')? If so sets L_ind (indent),
    ; L_mk (marker offset), L_mlen (marker length), L_ord (numbered?) and L_txt (text offset).
    sub list_s(uword s, uword n) -> bool {
        uword i = 0
        uword ind = 0
        uword st
        ubyte c
        while i < n and is_sp(@(s + i)) {
            if @(s + i) == TAB
                ind += 4
            else
                ind++
            i++
        }
        if i >= n
            return false
        L_ind = ind
        L_mk = i
        c = @(s + i)
        if (c == iso:'-' or c == iso:'*' or c == iso:'+') and (i + 1 >= n or @(s + i + 1) == SP) {
            L_ord = false
            L_mlen = 1
            i++
        } else if is_digit(c) {
            st = i
            while i < n and is_digit(@(s + i)) and i - st < 9
                i++
            if i >= n or (@(s + i) != iso:'.' and @(s + i) != iso:')') or (i + 1 < n and @(s + i + 1) != SP)
                return false
            i++
            L_ord = true
            L_mlen = i - st
        } else
            return false
        while i < n and @(s + i) == SP
            i++
        L_txt = i
        return true
    }

    ; Is this a table separator row (only - | : and spaces, with at least one - and one |)?
    sub sep_s(uword s, uword n) -> bool {
        uword i = 0
        bool dash = false
        bool pipe = false
        ubyte c
        while i < n {
            c = @(s + i)
            if c == iso:'-'
                dash = true
            else if c == iso:'|'
                pipe = true
            else if c != iso:':' and c != SP and c != TAB
                return false
            i++
        }
        return dash and pipe
    }

    ; Is this a setext underline (=== or ---) for the line above? Sets kind_lvl (1 or 2).
    sub setext_s(uword s, uword n) -> bool {
        uword i = 0
        uword cnt = 0
        ubyte c
        while i < n and @(s + i) == SP and i < 3
            i++
        if i >= n
            return false
        c = @(s + i)
        if c != iso:'=' and c != iso:'-'
            return false
        while i < n {
            if @(s + i) == c
                cnt++
            else if @(s + i) != SP
                return false
            i++
        }
        if c == iso:'-' and cnt < 2
            return false
        if c == iso:'='
            kind_lvl = 1
        else
            kind_lvl = 2
        return true
    }

    ; Is this line exactly [TOC] (any case, surrounding blanks allowed)?
    sub toc_s(uword s, uword n) -> bool {
        while n != 0 and is_sp(@(s + n - 1))
            n--
        while n != 0 and @(s) == SP {
            s++
            n--
        }
        return n == 5 and @(s) == iso:'[' and @(s + 4) == iso:']' and (@(s + 1) | 32) == iso:'t' and
               (@(s + 2) | 32) == iso:'o' and (@(s + 3) | 32) == iso:'c'
    }

    ; Classify source line l: one of the LK_* kinds. The order of the tests matters (a '---'
    ; line is a rule, but under a paragraph line it is a setext underline instead, which is
    ; why the NEXT line is inspected for tables and setext headings). Sets kind_lvl for headings.
    sub line_kind(uword l) -> ubyte {
        uword s
        uword n
        uword s2
        uword n2
        ubyte q
        ubyte q2
        ubyte lv

        eff(l)
        s = es
        n = en
        q = eq
        if blank_s(s, n)
            return LK_BLANK
        if fence_s(s, n)
            return LK_FENCE
        if atx_s(s, n) {
            kind_lvl = atx_lvl
            return LK_ATX
        }
        if toc_s(s, n)
            return LK_TOCM
        if hr_s(s, n)
            return LK_HR
        if list_s(s, n)
            return LK_LIST
        if l + 1 < nlines {
            eff(l + 1)
            s2 = es
            n2 = en
            q2 = eq
            if q2 == q {
                if has_char(s, n, iso:'|') and sep_s(s2, n2)
                    return LK_TABLE
                if setext_s(s2, n2)
                    return LK_SETEXT
            }
        }
        return LK_PARA
    }

    uword ht_s
    uword ht_n

    ; Heading i's visible text without the leading/trailing #'s -> ht_s, ht_n.
    sub heading_text(ubyte i) {
        uword s
        uword n
        uword off = 0
        eff(hl[i])
        s = es
        n = en
        if atx_s(s, n) {
            s += atx_off
            n -= atx_off
            while n != 0 and @(s + n - 1) == SP
                n--
            while n != 0 and @(s + n - 1) == iso:'#'
                n--
            while n != 0 and @(s + n - 1) == SP
                n--
        } else {
            while off < n and @(s + off) == SP
                off++
            s += off
            n -= off
            while n != 0 and @(s + n - 1) == SP
                n--
        }
        ht_s = s
        ht_n = n
    }

    ; Collect all headings (outside code fences) into hl[] (line), hlv[] (level),
    ; up to MAXH. Used for the contents menu, the preview's [TOC] and jumping.
    sub scan_headings() {
        uword l = 0
        bool infence = false
        ubyte k
        hn = 0
        while l < nlines and hn < MAXH {
            k = line_kind(l)
            if infence {
                if k == LK_FENCE
                    infence = false
            } else if k == LK_FENCE {
                infence = true
            } else if k == LK_ATX {
                hl[hn] = l
                hlv[hn] = kind_lvl
                hn++
            } else if k == LK_SETEXT {
                hl[hn] = l
                hlv[hn] = kind_lvl
                hn++
                l++
            }
            l++
        }
    }

    ; ---------------------------------------------------------------
    ; inline markup helpers shared by editor colouring and preview
    ; ---------------------------------------------------------------
    ; May the run of '*' or '_' at s[i] (width w: 1 = italic, 2 = bold) open or close emphasis?
    ; `on` says whether that style is currently open. A marker must touch text on the inside,
    ; and '_' inside a word (snake_case) never counts.
    sub emph_ok(uword s, uword n, uword i, ubyte w, bool on) -> bool {
        ubyte c = @(s + i)
        ubyte prev = SP
        ubyte next = SP
        if i != 0
            prev = @(s + i - 1)
        if i + w < n
            next = @(s + i + w)
        if not on
            return next != SP and not (c == iso:'_' and is_alnum(prev))
        return prev != SP and not (c == iso:'_' and is_alnum(next))
    }

    ; Is there a complete [text](url) starting at s[i] == '['?
    ; If so sets lk_rb (the ']') and lk_rp (the ')').
    sub link_at(uword s, uword n, uword i) -> bool {
        uword j = i + 1
        uword k
        while j < n and @(s + j) != iso:']'
            j++
        if j + 1 >= n or @(s + j + 1) != iso:'('
            return false
        k = j + 2
        while k < n and @(s + k) != iso:')'
            k++
        if k >= n
            return false
        lk_rb = j
        lk_rp = k
        return true
    }

    ; ---------------------------------------------------------------
    ; preview renderer -> banked RAM
    ; ---------------------------------------------------------------
    const ubyte ST_B = 1
    ubyte[80] prch
    ubyte[80] prco           ; row under construction
    ubyte[80] wch
    ubyte[80] wco            ; pending word
    ubyte[80] cch
    ubyte[80] cco            ; table cell sink
    ubyte px
    ubyte wn
    ubyte cn
    bool sink
    bool rowdirty
    bool lastblank
    bool pv_full
    ubyte margin
    ubyte qd
    bool bul_pend
    ubyte bul_x
    ubyte bul_len
    ubyte[12] bul_buf
    uword pv_n
    ubyte hcur

    bool st_b
    bool st_i
    bool st_c
    bool st_s
    bool st_link
    bool st_img
    bool hmode
    ubyte base_col
    bool prev_sp
    uword lk_end
    uword lk_close

    ; Preview storage: row n lives in bank 1 + n/51 at $A000 + (n%51)*160. This selects that
    ; bank and returns the row's address (caller must switch back to bank 0 afterwards).
    sub pv_addr(uword n) -> uword {
        ; selects the bank holding preview row n, returns its address in $A000
        cx16.rambank(pv_lo + lsb(n / PV_PER_BANK))
        return $a000 + (n % PV_PER_BANK) * 160
    }

    ; Store the finished row under construction (prch/prco) in banked RAM and count it.
    ; Sets pv_full when the 510-row limit is reached.
    sub row_flush() {
        uword p
        lastblank = false
        if pv_n >= pvmax {
            pv_full = true
            return
        }
        p = pv_addr(pv_n)
        sys.memcopy(&prch, p, SW)
        sys.memcopy(&prco, p + 80, SW)
        cx16.rambank(0)
        pv_n++
    }

    ; Start a new preview row: blanks, the quote bars for block quotes, the left margin and,
    ; if a list bullet is pending, the bullet itself.
    sub row_begin() {
        ubyte i
        sys.memset(&prch, SW, SP)
        sys.memset(&prco, SW, C_NORM)
        i = 0
        while i < qd {
            prch[i * 2] = G_V
            prco[i * 2] = C_QBAR
            i++
        }
        px = margin
        rowdirty = false
        if bul_pend {
            i = 0
            while i < bul_len and bul_x + i < pw {
                prch[bul_x + i] = bul_buf[i]
                prco[bul_x + i] = C_BUL
                i++
            }
            bul_pend = false
            rowdirty = true
        }
    }

    ; Finish the current row if anything was put on it.
    sub row_end() {
        if rowdirty
            row_flush()
        rowdirty = false
    }

    ; Emit one blank row, but never two in a row.
    sub blank_row() {
        if lastblank
            return
        row_begin()
        row_flush()
        lastblank = true
    }

    ; Place the pending word (wch/wco) on the row, wrapping to a new row first if it will not fit.
    sub wflush() {
        ubyte i
        if wn == 0
            return
        if px + wn > pw and px > margin {
            row_flush()
            row_begin()
        }
        i = 0
        while i < wn {
            if px >= pw {
                row_flush()
                row_begin()
            }
            prch[px] = wch[i]
            prco[px] = wco[i]
            px++
            i++
        }
        wn = 0
        rowdirty = true
    }

    ; Send one glyph to the preview. Spaces flush the pending word; other characters are collected
    ; into it. In `sink` mode (table cells) glyphs go to cch/cco instead, to measure or place them.
    sub out_glyph(ubyte g, ubyte col, bool sp) {
        if sink {
            if cn < SW {
                cch[cn] = g
                cco[cn] = col
                cn++
            }
            return
        }
        if sp {
            wflush()
            if px > margin and px < pw {
                prch[px] = SP
                prco[px] = col
                px++
            }
        } else {
            if wn >= SW
                wflush()
            wch[wn] = g
            wco[wn] = col
            wn++
        }
    }

    ; Reset the inline-style state (bold, italic, code, strike, link, image) for a new block.
    sub inl_reset() {
        st_b = false
        st_i = false
        st_c = false
        st_s = false
        st_link = false
        st_img = false
        prev_sp = true
    }

    ; Emit character c in the current inline style: picks the colour (code, link, image, strike,
    ; bold, italic, or the block's base colour) and the bold/italic glyph.
    sub put_styled(ubyte c) {
        ubyte g = c
        ubyte col = base_col
        if st_c {
            col = C_CODE
        } else {
            if st_link
                col = C_LINK
            else if st_img
                col = C_IMG
            else if st_s
                col = C_STRIKE
            else if not hmode {
                if st_b
                    col = C_BOLD
                else if st_i
                    col = C_ITAL
            }
            if st_b or hmode
                g = bold_glyph(c)
            else if st_i
                g = ital_glyph(c)
        }
        out_glyph(g, col, c == SP)
    }

    ; Render one line of inline Markdown: **bold** __bold__ *italic* _italic_ `code` ~~strike~~
    ; [links](url) ![images](url) and backslash escapes. Link/image URLs are hidden; the
    ; text is coloured. Runs of spaces collapse to one (outside code).
    sub inline_emit(uword s, uword n) {
        uword i = 0
        ubyte c
        ubyte w
        bool on
        while i < n {
            if (st_link or st_img) and i == lk_end {
                if st_img
                    put_styled(iso:']')
                st_link = false
                st_img = false
                i = lk_close + 1
                continue
            }
            c = @(s + i)
            if c == TAB
                c = SP
            if c == SP {
                if not prev_sp
                    put_styled(SP)
                prev_sp = true
                i++
                continue
            }
            prev_sp = false
            if c == iso:'\\' and i + 1 < n and is_punct(@(s + i + 1)) {
                put_styled(@(s + i + 1))
                i += 2
                continue
            }
            if c == iso:'`' {
                st_c = not st_c
                i++
                continue
            }
            if st_c {
                if c < 32 or c > 126
                    c = iso:'?'
                put_styled(c)
                i++
                continue
            }
            if c == iso:'*' or c == iso:'_' {
                w = 1
                if i + 1 < n and @(s + i + 1) == c
                    w = 2
                if w == 2
                    on = st_b
                else
                    on = st_i
                if emph_ok(s, n, i, w, on) {
                    if w == 2
                        st_b = not st_b
                    else
                        st_i = not st_i
                    i += w
                    continue
                }
            } else if c == iso:'~' and i + 1 < n and @(s + i + 1) == iso:'~' {
                st_s = not st_s
                i += 2
                continue
            } else if c == iso:'[' and not st_link and not st_img and link_at(s, n, i) {
                st_link = true
                lk_end = lk_rb
                lk_close = lk_rp
                i++
                continue
            } else if c == iso:'!' and i + 1 < n and @(s + i + 1) == iso:'[' and not st_link and not st_img and link_at(s, n, i + 1) {
                st_img = true
                lk_end = lk_rb
                lk_close = lk_rp
                put_styled(iso:'[')
                i += 2
                continue
            }
            if c < 32 or c > 126
                c = iso:'?'
            put_styled(c)
            i++
        }
    }

    ; Between two source lines of one paragraph, insert a single space.
    sub inline_join() {
        if not prev_sp {
            put_styled(SP)
            prev_sp = true
        }
    }

    ; Start a block of text at left margin m with base colour col (h = heading: always bold).
    sub begin_text(ubyte m, ubyte col, bool h) {
        margin = m
        base_col = col
        hmode = h
        inl_reset()
        wn = 0
        row_begin()
    }

    ; Emit a horizontal rule across the preview in colour col.
    sub rule_row(ubyte col) {
        ubyte x
        row_begin()
        x = margin
        while x < pw {
            prch[x] = G_H
            prco[x] = col
            x++
        }
        row_flush()
    }

    ; Emit one line of a fenced code block (es/en) on a shaded background, tabs as 4 columns.
    sub code_row() {
        uword i = 0
        ubyte x = margin + 1
        ubyte c
        row_begin()
        c = margin
        while c < pw {
            prco[c] = C_CODEBLK
            c++
        }
        while i < en and x < pw {
            c = @(es + i)
            i++
            if c == TAB {
                x += 4
                continue
            }
            if c < 32 or c > 126
                c = iso:'?'
            prch[x] = c
            x++
        }
        row_flush()
    }

    ; Emit a heading: blank row, the text in the level's colour (bold), and for # and ##
    ; an underline rule. Records the heading's preview row in hvis[] for jumping.
    sub render_heading(ubyte lvl, uword s, uword n) {
        blank_row()
        if hcur < hn
            hvis[hcur] = pv_n
        hcur++
        begin_text(qd * 2, hcol[lvl], true)
        inline_emit(s, n)
        wflush()
        row_end()
        if lvl == 1
            rule_row(hcol[1])
        else if lvl == 2
            rule_row(C_TBL)
        blank_row()
    }

    ; --- tables ---
    uword[8] tc_s
    uword[8] tc_e
    ubyte[8] t_w
    ubyte[8] t_al
    ubyte t_nc
    ubyte tx

    ; Split a table row into cells (leading/trailing '|' optional, `\|` is escaped).
    ; Cell i's text is s[tc_s[i] .. tc_e[i]) with blanks trimmed. Returns the cell count (max 8).
    sub split_row(uword s, uword n) -> ubyte {
        uword i = 0
        uword st
        uword e
        ubyte c = 0
        while i < n and is_sp(@(s + i))
            i++
        if i < n and @(s + i) == iso:'|'
            i++
        while i < n and c < MAXC {
            st = i
            while i < n and @(s + i) != iso:'|' {
                if @(s + i) == iso:'\\' and i + 1 < n
                    i++
                i++
            }
            e = i
            while st < e and is_sp(@(s + st))
                st++
            while e > st and is_sp(@(s + e - 1))
                e--
            tc_s[c] = st
            tc_e[c] = e
            c++
            if i < n
                i++
        }
        return c
    }

    ; Render cell c of a row into the sink (cch/cco) so its width cn is known.
    sub cell_measure(uword s, ubyte c, bool header) {
        sink = true
        cn = 0
        if header
            base_col = 7
        else
            base_col = C_NORM
        hmode = header
        inl_reset()
        inline_emit(s + tc_s[c], tc_e[c] - tc_s[c])
        sink = false
    }

    ; Put one glyph into the table row being built at column tx.
    sub tbl_put(ubyte g, ubyte col) {
        if tx < pw {
            prch[tx] = g
            prco[tx] = col
            tx++
        }
    }

    ; Emit a table border row using the given left / middle / right box glyphs.
    sub tbl_border(ubyte gl, ubyte gm, ubyte gr) {
        ubyte c
        ubyte k
        row_begin()
        tx = margin
        tbl_put(gl, C_TBL)
        c = 0
        while c < t_nc {
            k = 0
            while k < t_w[c] + 2 {
                tbl_put(G_H, C_TBL)
                k++
            }
            if c + 1 < t_nc
                tbl_put(gm, C_TBL)
            else
                tbl_put(gr, C_TBL)
            c++
        }
        row_flush()
    }

    ; Emit one table row: each cell padded to its column width according to its alignment
    ; (t_al: 0 left, 1 centre, 2 right); text that is too wide is cut with a '~'.
    sub tbl_row(uword s, uword n, bool header) {
        ubyte c
        ubyte shown
        ubyte pad
        ubyte lp
        ubyte k
        ubyte ncell
        ncell = split_row(s, n)
        row_begin()
        tx = margin
        tbl_put(G_V, C_TBL)
        c = 0
        while c < t_nc {
            if c < ncell
                cell_measure(s, c, header)
            else
                cn = 0
            if cn > t_w[c]
                shown = t_w[c]
            else
                shown = cn
            pad = t_w[c] - shown
            if t_al[c] == 2
                lp = pad
            else if t_al[c] == 1
                lp = pad / 2
            else
                lp = 0
            tbl_put(SP, C_NORM)
            k = 0
            while k < lp {
                tbl_put(SP, C_NORM)
                k++
            }
            k = 0
            while k < shown {
                if cn > t_w[c] and k + 1 == shown
                    tbl_put(iso:'~', C_TBL)
                else
                    tbl_put(cch[k], cco[k])
                k++
            }
            k = lp
            while k < pad {
                tbl_put(SP, C_NORM)
                k++
            }
            tbl_put(SP, C_NORM)
            tbl_put(G_V, C_TBL)
            c++
        }
        row_flush()
    }

    ; Render the table starting at line l (header, separator row, body rows). First reads the
    ; alignments from the separator row, then measures every cell to get column widths, then
    ; shrinks the widest columns until the table fits the screen. Returns the first line after it.
    sub render_table(uword l) -> uword {
        uword t
        uword r
        uword s
        uword n
        uword tot
        uword a
        uword b
        ubyte c
        ubyte nc
        ubyte nn
        ubyte avail
        ubyte widest

        ; separator row: alignment
        eff(l + 1)
        s = es
        n = en
        nc = split_row(s, n)
        c = 0
        while c < nc {
            a = tc_s[c]
            b = tc_e[c]
            t_al[c] = 0
            if b > a and @(s + b - 1) == iso:':' {
                if @(s + a) == iso:':'
                    t_al[c] = 1
                else
                    t_al[c] = 2
            }
            c++
        }
        eff(l)
        t_nc = split_row(es, en)
        if t_nc == 0
            t_nc = 1
        c = 0
        while c < t_nc {
            t_w[c] = 1
            c++
        }
        ; measure
        r = l
        while r < nlines {
            eff(r)
            s = es
            n = en
            if r != l and r != l + 1 and (blank_s(s, n) or not has_char(s, n, iso:'|'))
                break
            if r != l + 1 {
                nn = split_row(s, n)
                c = 0
                while c < t_nc and c < nn {
                    cell_measure(s, c, r == l)
                    if cn > t_w[c] {
                        if cn > 70
                            t_w[c] = 70
                        else
                            t_w[c] = cn
                    }
                    c++
                }
            }
            r++
        }
        t = r
        tot = 1
        c = 0
        while c < t_nc {
            tot += t_w[c] + 3
            c++
        }
        avail = pw - margin
        while tot > avail {
            widest = 0
            c = 1
            while c < t_nc {
                if t_w[c] > t_w[widest]
                    widest = c
                c++
            }
            if t_w[widest] <= 3
                break
            t_w[widest]--
            tot--
        }
        blank_row()
        tbl_border(G_TL, G_T, G_TR)
        eff(l)
        tbl_row(es, en, true)
        tbl_border(G_L, G_X, G_R)
        r = l + 2
        while r < t {
            eff(r)
            tbl_row(es, en, false)
            r++
        }
        tbl_border(G_BL, G_B, G_BR)
        blank_row()
        return t
    }

    ; Render a constant string as inline text.
    sub emit_str(uword s) {
        inline_emit(s, slen(s))
    }

    ; Expand a [TOC] marker into a bulleted, indented list of every heading.
    sub render_toc() {
        ubyte i
        ubyte minlv = 7
        ubyte ind
        if hn == 0
            return
        i = 0
        while i < hn {
            if hlv[i] < minlv
                minlv = hlv[i]
            i++
        }
        blank_row()
        begin_text(qd * 2, C_TOC, true)
        emit_str(iso:"Contents")
        wflush()
        row_end()
        i = 0
        while i < hn {
            ind = (hlv[i] - minlv) * 2
            bul_pend = true
            bul_x = qd * 2 + ind
            bul_len = 1
            bul_buf[0] = G_BUL
            begin_text(bul_x + 2, C_NORM, false)
            heading_text(i)
            inline_emit(ht_s, ht_n)
            wflush()
            row_end()
            i++
        }
        blank_row()
    }

    ; Render the whole document into preview rows. Dispatches on line_kind(): blank, fenced code,
    ; headings (ATX and setext), rules, [TOC], tables, list items and paragraphs. Consecutive
    ; paragraph lines (in the same quote level) are joined into one wrapped paragraph.
    ; The preview rows go into whatever banks the document is not using: everything above the
    ; highest page of the working chain and of the undo snapshot.
    ; The preview rows go in the banks above the frames that hold changed pages. Clean copies are
    ; dropped first, and until the editor is back (frlim = nfrm) no frame up there is used.
    sub pv_setup() {
        uword f = 0
        uword t = 16                      ; keep at least two banks of frames for reading pages
        flush_all()
        while f < nfrm {
            when fstate(f) {
                FR_ONLY -> {
                    if f >= t
                        t = f + 1
                }
                FR_CLEAN -> {
                    wset(B_FR, wget(B_FRM, f), NIL)
                    set_fstate(f, FR_FREE)
                }
            }
            f++
        }
        frlim = (t + 7) & $fff8
        if frlim > nfrm
            frlim = nfrm
        pv_lo = DOC_BANK0 + lsb(frlim >> 3)
        pvmax = (nbanks - pv_lo) * PV_PER_BANK
    }

    sub pv_render() {
        uword l = 0
        uword s
        uword n
        ubyte k
        ubyte q
        ubyte lv
        ubyte b
        ubyte j

        pv_setup()
        scan_headings()
        j = 0
        while j < MAXH {
            hvis[j] = $ffff
            j++
        }
        pv_n = 0
        pv_full = false
        lastblank = true
        hcur = 0
        sink = false
        bul_pend = false
        qd = 0
        margin = 0
        wn = 0
        while l < nlines and not pv_full {
            k = line_kind(l)
            eff(l)
            s = es
            n = en
            q = eq
            qd = q
            when k {
                LK_BLANK -> {
                    blank_row()
                    l++
                }
                LK_FENCE -> {
                    blank_row()
                    margin = qd * 2
                    l++
                    while l < nlines and not pv_full {
                        eff(l)
                        if fence_s(es, en) {
                            l++
                            break
                        }
                        qd = eq
                        margin = qd * 2
                        code_row()
                        l++
                    }
                    blank_row()
                }
                LK_ATX -> {
                    void atx_s(s, n)
                    lv = atx_lvl
                    s += atx_off
                    n -= atx_off
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    while n != 0 and @(s + n - 1) == iso:'#'
                        n--
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    render_heading(lv, s, n)
                    l++
                }
                LK_SETEXT -> {
                    lv = kind_lvl
                    while n != 0 and @(s) == SP {
                        s++
                        n--
                    }
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    render_heading(lv, s, n)
                    l += 2
                }
                LK_HR -> {
                    blank_row()
                    margin = qd * 2
                    rule_row(C_TBL)
                    blank_row()
                    l++
                }
                LK_TOCM -> {
                    render_toc()
                    l++
                }
                LK_TABLE -> {
                    margin = qd * 2
                    l = render_table(l)
                }
                LK_LIST -> {
                    void list_s(s, n)
                    if L_ind > 12
                        b = 12
                    else
                        b = lsb(L_ind)
                    bul_x = qd * 2 + b
                    if L_ord {
                        if L_mlen > 8
                            bul_len = 8
                        else
                            bul_len = lsb(L_mlen)
                        sys.memcopy(s + L_mk, &bul_buf, bul_len)
                    } else {
                        bul_len = 1
                        bul_buf[0] = G_BUL
                    }
                    bul_pend = true
                    begin_text(bul_x + bul_len + 1, C_NORM, false)
                    inline_emit(s + L_txt, n - L_txt)
                    repeat {
                        if l + 1 >= nlines
                            break
                        if line_kind(l + 1) != LK_PARA
                            break
                        eff(l + 1)
                        if eq != q
                            break
                        inline_join()
                        inline_emit(es, en)
                        l++
                    }
                    wflush()
                    row_end()
                    l++
                }
                else -> {                        ; paragraph
                    begin_text(qd * 2, C_NORM, false)
                    inline_emit(s, n)
                    repeat {
                        if l + 1 >= nlines
                            break
                        if line_kind(l + 1) != LK_PARA
                            break
                        eff(l + 1)
                        if eq != q
                            break
                        inline_join()
                        inline_emit(es, en)
                        l++
                    }
                    wflush()
                    row_end()
                    l++
                }
            }
        }
        qd = 0
        if pv_n == 0 {
            row_begin()
            row_flush()
        }
    }

    ; ---------------------------------------------------------------
    ; text drawing helpers
    ; ---------------------------------------------------------------
    ; Draw a NUL-terminated string on a full screen row, padding with spaces.
    sub draw_text(ubyte row, uword s, ubyte col) {
        ubyte x = 0
        vera_at(0, row)
        while x < scrw {
            if @(s) != 0 {
                cx16.VERA_DATA0 = @(s)
                s++
            } else
                cx16.VERA_DATA0 = SP
            cx16.VERA_DATA0 = col
            x++
        }
    }

    ; Copy preview row n from banked RAM to screen row y (blank if past the end).
    sub pv_draw_row(ubyte y, uword n) {
        uword p
        ubyte x
        vera_at(0, y)
        if n >= pv_n {
            x = 0
            while x < scrw {
                cx16.VERA_DATA0 = SP
                cx16.VERA_DATA0 = C_NORM
                x++
            }
            return
        }
        p = pv_addr(n)
        x = 0
        while x < scrw {
            cx16.VERA_DATA0 = @(p + x)
            cx16.VERA_DATA0 = @(p + 80 + x)
            x++
        }
        cx16.rambank(0)
    }

    ; ---------------------------------------------------------------
    ; dialogs: line prompt, help, TOC menu
    ; ---------------------------------------------------------------
    ; Prompt on the bottom line and edit a line of text in `out` (which may hold a default).
    ; Enter accepts (true), Esc cancels (false); backspace works.
    sub read_line(uword prompt, uword out, ubyte maxn) -> bool {
        ubyte n = slen(out)
        ubyte k
        ubyte d
        repeat {
            d = bcat(&rline, 0, prompt)
            k = 0
            while k < n {
                rline[d] = @(out + k)
                d++
                k++
            }
            rline[d] = iso:'_'
            rline[d + 1] = 0
            draw_text(scrh - 1, &rline, (C_BG << 4) | C_BOLD)
            k = getkey()
            if k == K_ESC {
                @(out) = 0
                return false
            }
            if k == 13 or k == 10 {
                @(out + n) = 0
                return true
            }
            if k == K_BKSP or k == $08 or k == $7f {
                if n != 0
                    n--
                @(out + n) = 0
                continue
            }
            if k >= 32 and k < 127 and n < maxn - 1 {
                @(out + n) = k
                n++
                @(out + n) = 0
            }
        }
    }

    ; F1: a one-screen key summary.
    sub show_help() {
        clear_screen()
        draw_text(1, iso:"MD - Markdown editor", C_TOC)
        draw_text(3, iso:"^W/F2 save   ^O/F3 open   ^X/F8 quit", C_NORM)
        draw_text(4, iso:"^P/F5 preview (toggle)    ^G/F4 contents", C_NORM)
        draw_text(5, iso:"^Z undo/redo  ^U kill line  ^F find", C_NORM)
        draw_text(6, iso:"F6/F7 page up/down", C_NORM)
        draw_text(7, iso:"^B bold  ^E italic  ^K code", C_NORM)
        draw_text(8, iso:"^A table  ^R [TOC] marker", C_NORM)
        draw_text(10, iso:"Preview: arrows, Space, b, n/p heading,", C_NORM)
        draw_text(11, iso:"  F4 contents, Esc or ^P back to editor", C_NORM)
        draw_text(13, iso:"Press any key", C_NORM)
        void getkey()
        redraw_all = true
    }

    ; The table-of-contents popup: a scrolling list of headings indented by level.
    ; Up/Down/F6/F7/Home/End move, Enter returns the heading index, Esc returns 255.
    sub toc_menu() -> ubyte {
        ubyte sel = 0
        ubyte first = 0
        ubyte vis
        ubyte i
        ubyte x
        ubyte bw
        ubyte bx
        ubyte by
        ubyte k
        ubyte minlv = 7
        ubyte ind
        ubyte col
        ubyte m
        uword j
        ubyte[81] line
        str title = iso:" Table of Contents  (Enter=go  Esc=cancel) "

        scan_headings()
        if hn == 0 {
            setmsg(iso:"No headings in this document")
            return 255
        }
        i = 0
        while i < hn {
            if hlv[i] < minlv
                minlv = hlv[i]
            i++
        }
        if scrw > 66
            bw = 64
        else
            bw = scrw - 2
        bx = (scrw - bw) / 2
        vis = textrows - 4
        if vis > hn
            vis = hn
        by = 2
        repeat {
            ; frame
            x = 0
            while x < bw {
                put_cell(bx + x, by - 1, SP, (1 << 4) | 0)
                x++
            }
            x = 0
            while title[x] != 0 and x < bw {
                put_cell(bx + x, by - 1, title[x], (1 << 4) | 0)
                x++
            }
            i = 0
            while i < vis {
                m = first + i
                sys.memset(&line, bw, SP)
                ind = (hlv[m] - minlv) * 2
                heading_text(m)
                x = 1 + ind
                j = 0
                while j < ht_n and x < bw - 1 {
                    k = @(ht_s + j)
                    j++
                    if k == iso:'*' or k == iso:'`'
                        continue
                    if k < 32 or k > 126
                        k = iso:'?'
                    line[x] = k
                    x++
                }
                if m == sel
                    col = (1 << 4) | 0
                else
                    col = (11 << 4) | hcol[hlv[m]]
                x = 0
                while x < bw {
                    put_cell(bx + x, by + i, line[x], col)
                    x++
                }
                i++
            }
            x = 0
            while x < bw {
                put_cell(bx + x, by + vis, SP, (1 << 4) | 0)
                x++
            }
            k = getkey()
            if k == K_ESC or k == K_F4 or k == CTRL_G
                return 255
            if k == 13 or k == 10
                return sel
            if k == K_DOWN and sel + 1 < hn
                sel++
            else if k == K_UP and sel != 0
                sel--
            else if k == K_F7 and sel + vis < hn
                sel += vis
            else if k == K_F7
                sel = hn - 1
            else if k == K_F6 {
                if sel > vis
                    sel -= vis
                else
                    sel = 0
            } else if k == K_HOME
                sel = 0
            else if k == K_END
                sel = hn - 1
            if sel < first
                first = sel
            if sel >= first + vis
                first = sel - vis + 1
        }
    }

    ; ---------------------------------------------------------------
    ; preview viewer
    ; ---------------------------------------------------------------
    ; The preview viewer. Renders the document, starts at the heading nearest above the editing
    ; cursor, then loops reading keys: scroll, page, next/previous heading, contents menu,
    ; and Esc / Ctrl-P to return to the editor.
    sub preview_mode() {
        uword pvtop = 0
        uword maxtop
        ubyte i
        ubyte k
        ubyte t
        ubyte d

        draw_text(scrh - 1, iso:"Rendering preview...", (C_BG << 4) | C_BOLD)
        pv_render()
        ; start at the heading nearest above the cursor
        i = 0
        while i < hn {
            if hl[i] <= cy
                pvtop = hvis[i]
            i++
        }
        repeat {
            if pv_n > textrows
                maxtop = pv_n - textrows
            else
                maxtop = 0
            if pvtop > maxtop
                pvtop = maxtop
            i = 0
            while i < textrows {
                pv_draw_row(i, pvtop + i)
                i++
            }
            d = bcat(&sline, 0, iso:" PREVIEW  ")
            if fname[0] != 0
                d = bcat(&sline, d, &fname)
            else
                d = bcat(&sline, d, iso:"[No Name]")
            d = bcat(&sline, d, iso:"   row ")
            d = bnum(&sline, d, pvtop + 1)
            sline[d] = iso:'/'
            d++
            d = bnum(&sline, d, pv_n)
            if pv_full
                d = bcat(&sline, d, iso:" (too long: end cut off)")
            sline[d] = 0
            draw_text(scrh - 2, &sline, (C_NORM << 4) | C_BG)
            draw_text(scrh - 1, iso:"Up/Dn scroll  Space page  n/p heading  F4 contents  Ctrl-P or Esc = edit",
                      (C_BG << 4) | C_LAB)
            k = getkey()
            when k {
                K_DOWN, iso:'j' -> {
                    if pvtop < maxtop
                        pvtop++
                }
                K_UP, iso:'k' -> {
                    if pvtop != 0
                        pvtop--
                }
                SP, K_F7, iso:'f' -> pvtop += textrows - 1
                iso:'b', K_F6 -> {
                    if pvtop > textrows - 1
                        pvtop -= textrows - 1
                    else
                        pvtop = 0
                }
                K_HOME, iso:'g' -> pvtop = 0
                K_END, iso:'G' -> pvtop = maxtop
                iso:'n' -> {
                    i = 0
                    while i < hn {
                        if hvis[i] > pvtop and hvis[i] < pv_n {
                            pvtop = hvis[i]
                            break
                        }
                        i++
                    }
                }
                iso:'p' -> {
                    i = hn
                    while i != 0 {
                        i--
                        if hvis[i] < pvtop {
                            pvtop = hvis[i]
                            break
                        }
                    }
                }
                K_F4, iso:'t', CTRL_G -> {
                    t = toc_menu()
                    if t != 255
                        pvtop = hvis[t]
                }
                K_F5, CTRL_P, K_ESC, iso:'e', iso:'q' -> {
                    frlim = nfrm
                    redraw_all = true
                    return
                }
            }
        }
    }

    ; ---------------------------------------------------------------
    ; editor: syntax colouring
    ; ---------------------------------------------------------------
    ; Give characters fstart..fend-1 of the line being drawn the colour `col` (in cls).
    sub fillc(uword fstart, uword fend, ubyte col) {
        if fend > CLSN
            fend = CLSN
        while fstart < fend {
            cls[lsb(fstart)] = col
            fstart++
        }
    }

    ; Colour one source line for the editor: fence lines and fenced content, headings, [TOC], rules
    ; and table separators as a whole; otherwise block-quote bars, list markers, `code`, **bold**,
    ; *italic*, [text](url) and table pipes.
    sub hl_md(uword s, uword n, bool infence, bool isfence) {
        uword m
        uword i = 0
        uword j
        uword a
        uword b2
        ubyte c
        bool bo = false
        bool it = false
        bool cd = false
        ubyte k
        ubyte w
        bool on

        if n > CLSN
            m = CLSN
        else
            m = n
        fillc(0, m, C_NORM)
        if isfence {
            fillc(0, m, C_MARK)
            return
        }
        if infence {
            fillc(0, m, C_LAB)
            return
        }
        if atx_s(s, n) {
            fillc(0, m, hcol[atx_lvl])
            return
        }
        if toc_s(s, n) {
            fillc(0, m, C_TOC)
            return
        }
        if hr_s(s, n) or sep_s(s, n) {
            fillc(0, m, C_MARK)
            return
        }
        while i < m and @(s + i) == SP
            i++
        while i < m and @(s + i) == iso:'>' {
            cls[lsb(i)] = C_QBAR
            i++
            if i < m and @(s + i) == SP
                i++
        }
        if list_s(s, n) {
            fillc(L_mk, L_mk + L_mlen, C_BUL)
            i = L_txt
        }
        j = i
        while j < m {
            c = @(s + j)
            if c == iso:'`' {
                cls[lsb(j)] = C_MARK
                cd = not cd
                j++
                continue
            }
            if cd {
                cls[lsb(j)] = C_CODE & 15
                j++
                continue
            }
            if c == iso:'*' or c == iso:'_' {
                w = 1
                if j + 1 < n and @(s + j + 1) == c
                    w = 2
                if w == 2
                    on = bo
                else
                    on = it
                if emph_ok(s, n, j, w, on) {
                    fillc(j, j + w, C_MARK)
                    if w == 2
                        bo = not bo
                    else
                        it = not it
                    j += w
                    continue
                }
            } else if c == iso:'[' and link_at(s, n, j) {
                a = lk_rb
                b2 = lk_rp
                fillc(j, j + 1, C_MARK)
                fillc(j + 1, a, C_LINK)
                fillc(a, a + 2, C_MARK)
                fillc(a + 2, b2, C_URL)
                fillc(b2, b2 + 1, C_MARK)
                j = b2 + 1
                continue
            }
            if bo
                k = C_BOLD
            else if it
                k = C_ITAL
            else
                k = C_NORM
            cls[lsb(j)] = k
            j++
        }
        if has_char(s, m, iso:'|') {
            j = 0
            while j < m {
                if @(s + j) == iso:'|'
                    cls[lsb(j)] = C_TBL
                j++
            }
        }
    }

    ; Is line l inside a fenced code block? (Counts the fences above it, starting from the cached
    ; checkpoint or from line 0, whichever is nearer, so scrolling a long document stays quick.)
    sub fence_before(uword l) -> bool {
        uword i
        bool f
        if l < fc_l and fc_l - l < l {
            f = fc_f
            i = fc_l
            while i > l {
                i--
                if fence_s(lp(i), linelen(i))
                    f = not f
            }
        } else {
            if l >= fc_l {
                i = fc_l
                f = fc_f
            } else {
                i = 0
                f = false
            }
            while i < l {
                if fence_s(lp(i), linelen(i))
                    f = not f
                i++
            }
        }
        fc_l = l
        fc_f = f
        return f
    }

    ; Screen rows used by logical line l when wrapped to the screen width.
    sub rows_of(uword l) -> uword {
        return linelen(l) / scrw + 1
    }

    ; Draw logical line l starting at screen row `row`, wrapping it over as many rows as it needs.
    ; f = whether the line starts inside a code fence. Returns the number of rows used.
    sub draw_logical(uword l, ubyte row, bool f) -> ubyte {
        uword s = lp(l)
        uword n = linelen(l)
        uword idx
        ubyte segs = lsb(n / scrw + 1)
        ubyte sg = 0
        ubyte x
        ubyte ch
        ubyte used = 0
        bool isf = fence_s(s, n)

        hl_md(s, n, f, isf)
        while sg < segs and row + used < textrows {
            vera_at(0, row + used)
            idx = (sg as uword) * scrw
            x = 0
            while x < scrw {
                if idx < n {
                    ch = @(s + idx)
                    if ch < 32 or ch > 126 {
                        if ch == TAB
                            ch = SP
                        else
                            ch = iso:'?'
                    }
                    cx16.VERA_DATA0 = ch
                    if idx < CLSN
                        cx16.VERA_DATA0 = cls[lsb(idx)]
                    else
                        cx16.VERA_DATA0 = C_NORM
                } else {
                    cx16.VERA_DATA0 = SP
                    cx16.VERA_DATA0 = C_NORM
                }
                x++
                idx++
            }
            used++
            sg++
        }
        return used
    }

    ; Redraw the whole text area from line `top`; `~` marks rows past the end of the file.
    sub draw_screen() {
        uword l = top
        ubyte row = 0
        bool f = fence_before(top)
        ubyte x
        while row < textrows {
            if l >= nlines {
                vera_at(0, row)
                cx16.VERA_DATA0 = iso:'~'
                cx16.VERA_DATA0 = C_LAB
                x = 1
                while x < scrw {
                    cx16.VERA_DATA0 = SP
                    cx16.VERA_DATA0 = C_NORM
                    x++
                }
                row++
                continue
            }
            row += draw_logical(l, row, f)
            if fence_s(lp(l), linelen(l))
                f = not f
            l++
        }
    }

    ; Screen row where logical line l starts, or 255 if it is not on screen.
    sub line_row(uword l) -> ubyte {
        uword r = 0
        uword i
        if l < top
            return 255
        i = top
        while i < l {
            r += rows_of(i)
            if r >= textrows
                return 255
            i++
        }
        return lsb(r)
    }

    ubyte cur_x
    ubyte cur_y

    ; Compute the cursor's screen position (cur_x, cur_y), accounting for wrapped lines above it.
    sub cursor_xy() {
        uword r = 0
        uword i = top
        while i < cy {
            r += rows_of(i)
            if r > 200
                break
            i++
        }
        r += cx / scrw
        cur_x = lsb(cx % scrw)
        if r > 250
            cur_y = 250
        else
            cur_y = lsb(r)
    }

    ; Two bottom rows: the status line (file, [+] modified, line/column, free bytes) and a message
    ; or the key hints.
    sub draw_status() {
        ubyte d = 0
        ubyte e
        ubyte i
        d = bcat(&sline, d, iso:" ")
        if fname[0] != 0
            d = bcat(&sline, d, &fname)
        else
            d = bcat(&sline, d, iso:"[No Name]")
        if modified
            d = bcat(&sline, d, iso:" [+]")
        while d < scrw {
            sline[d] = SP
            d++
        }
        e = bcat(&rbuf, 0, iso:"Ln ")
        e = bnum(&rbuf, e, cy + 1)
        e = bcat(&rbuf, e, iso:" Col ")
        e = bnum(&rbuf, e, cx + 1)
        e = bcat(&rbuf, e, iso:"  Free ")
        e = bnum(&rbuf, e, avail())
        e = bcat(&rbuf, e, iso:"K")
        rbuf[e] = SP
        e++
        i = 0
        while i < e {
            sline[scrw - e + i] = rbuf[i]
            i++
        }
        sline[scrw] = 0
        draw_text(scrh - 2, &sline, (C_NORM << 4) | C_BG)
        if msg[0] != 0
            draw_text(scrh - 1, &msg, (C_BG << 4) | C_BOLD)
        else
            draw_text(scrh - 1, iso:"^P preview  ^G contents  ^W save  ^O open  ^X quit  ^B bold ^E italic  F1 help",
                      (C_BG << 4) | C_LAB)
    }

    ; Scroll (change `top`) so the cursor row is visible.
    sub scroll_to_cursor() {
        if cy < top {
            top = cy
            redraw_all = true
        }
        if cy > top + textrows {              ; far away (find, goto): jump instead of stepping line by line
            top = cy - (textrows >> 1)
            redraw_all = true
        }
        repeat {
            cursor_xy()
            if cur_y < textrows or top >= cy
                break
            top++
            redraw_all = true
        }
    }

    ; Redraw what changed -- everything if redraw_all, else just the old and new cursor lines --
    ; then the status and the cursor (shown by inverting its cell).
    sub refresh() {
        ubyte r
        ubyte ch
        scroll_to_cursor()
        if redraw_all {
            draw_screen()
            redraw_all = false
        } else {
            if prev_cy != cy {
                r = line_row(prev_cy)
                if r != 255 and prev_cy < nlines
                    void draw_logical(prev_cy, r, fence_before(prev_cy))
            }
            r = line_row(cy)
            if r != 255
                void draw_logical(cy, r, fence_before(cy))
        }
        prev_cy = cy
        draw_status()
        cursor_xy()
        if cur_y < textrows {
            vera_at(cur_x, cur_y)
            ch = cx16.VERA_DATA0
            put_cell(cur_x, cur_y, ch, (C_NORM << 4) | C_BG)
        }
    }

    ; ---------------------------------------------------------------
    ; cursor movement
    ; ---------------------------------------------------------------
    ; Remember the cursor's screen column so Up/Down can return to it on shorter lines.
    sub set_want() {
        want = cx % scrw
    }

    ; Keep the cursor within the line.
    sub clamp_cx() {
        uword n = linelen(cy)
        if cx > n
            cx = n
    }

    ; Down one SCREEN row: within a wrapped line first, then to the next line.
    sub move_down() {
        uword n = linelen(cy)
        uword w = scrw
        if cx / w < n / w {
            cx += w
            if cx > n
                cx = n
        } else if cy + 1 < nlines {
            cy++
            cx = want
            clamp_cx()
        }
    }

    ; Up one screen row, mirror of move_down.
    sub move_up() {
        uword w = scrw
        uword n
        if cx >= w
            cx -= w
        else if cy > 0 {
            cy--
            n = linelen(cy)
            cx = (n / w) * w + want
            if cx > n
                cx = n
        }
    }

    ; ---------------------------------------------------------------
    ; file i/o
    ; ---------------------------------------------------------------
    ; CMDR-DOS wants PETSCII file names: convert ASCII in place (a-z -> $41-$5A, A-Z -> $C1-$DA).
    sub dosname(uword d) {
        ubyte c
        while @(d) != 0 {
            c = @(d)
            if c >= iso:'a' and c <= iso:'z'
                c -= 32
            else if c >= iso:'A' and c <= iso:'Z'
                c += 128
            @(d) = c
            d++
        }
    }

    ; Read the drive's status line (e.g. "62,file not found,00,00") via channel 15.
    sub dos_status(uword out, ubyte maxn) {
        ubyte n = 0
        ubyte c
        ubyte i
        @(out) = 0
        cbm.SETNAM(0, 0)
        cbm.SETLFS(15, DEVICE, 15)
        void cbm.OPEN()
        void cbm.CHKIN(15)
        while n + 1 < maxn {
            c = cbm.CHRIN()
            if c == 13 or c == 10 or cbm.READST() != 0
                break
            @(out + n) = c
            n++
        }
        @(out + n) = 0
        i = 0
        while i < n {
            c = @(out + i)
            if c >= $41 and c <= $5a
                @(out + i) = c + 32
            i++
        }
        cbm.CLRCHN()
        cbm.CLOSE(15)
    }

    ; --- loading: the file is measured, not read into memory (see "paged document store") ---
    uword ld_o                ; bytes in the page being measured
    uword ld_lc               ; complete lines in it
    uword ld_tail             ; last page stored so far
    long ld_rs                ; file offset where the page being measured starts
    long ld_ls                ; file offset of the first byte of the current line
    long cv_base              ; file offset of RAWBUF[0]
    ubyte cv_i                ; index in RAWBUF of the byte being converted
    ubyte cv_n                ; end of the piece of RAWBUF being converted

    ; Record a page: its first nb bytes (nlns complete lines) of what has been measured, which came
    ; from file bytes ld_rs up to ld_ls. The partly measured line that follows starts the next page.
    sub ld_commit(uword nb, uword nlns) {
        uword g
        long rl = ld_ls - ld_rs
        if truncated
            return
        if nfree <= 16 or nlines + nlns > MAXLINES or rl > 60000 {
            truncated = true
            return
        }
        g = alloc_pg()
        setnx(g, NIL)
        setnl(g, lsb(nlns))
        wset(B_BL, g, nb)
        set_foff(g, ld_rs)
        wset(B_FLN, g, rl as uword)
        if head == NIL
            head = g
        else
            setnx(ld_tail, g)
        ld_tail = g
        nlines += nlns
        ld_o -= nb
        ld_lc -= nlns
        ld_rs = ld_ls
    }

    ; Count one converted byte, ending the page first when it is full.
    sub ld_note(ubyte c) {
        if cv_cl == 0
            ld_ls = cv_base + cv_i
        if ld_o >= FILL or ld_lc >= LPP - 2
            ld_commit(ld_o - cv_cl, ld_lc)
        ld_o++
        if c == NL
            ld_lc++
    }

    ; Open a file (device 8) as the document: scan it once to cut it into pages (CR/CRLF become LF,
    ; NULs are dropped, a final newline is added, lines longer than MAXLN are broken); the text is
    ; read later, page by page, as it is needed. `truncated` is set if it has more lines (or pages)
    ; than we can track. Returns false if it could not be read.
    sub load_file(uword name) -> bool {
        ubyte n
        pool_reset()
        copystr(&bkname, name, FNLEN)
        bk_open()
        truncated = false
        cv_scan = true
        cv_wrap = false
        cv_cl = 0
        cv_prev = 0
        cv_base = 0
        ld_o = 0
        ld_lc = 0
        ld_rs = 0
        repeat {
            n = bk_read(RAWBUF, RAWLEN)
            if n == 0
                break
            cv_n = n
            cv_i = 0
            while cv_i < n {
                cv_i = cv_fast(cv_i)
                if cv_i < n {
                    cv_byte(bget(B_FRM, RAWBUF - $a000 + cv_i))
                    cv_i++
                }
            }
            cv_base += n
            if truncated
                break
        }
        bk_close()
        dos_status(&dstat, 40)
        if dstat[0] == iso:'6' or dstat[0] == iso:'7' or (dstat[0] == iso:'5' and dstat[1] != iso:'0') {
            if ld_o == 0 and nlines == 0 {
                bkname[0] = 0
                setmsg(&dstat)
                return false
            }
        }
        if ld_o != 0 and not truncated {
            ld_ls = cv_base
            if cv_cl != 0 {                       ; no newline at the end: the page gets one
                ld_o++
                ld_lc++
            }
            ld_commit(ld_o, ld_lc)
        }
        if nlines == 0 {
            @(pbuf0) = NL
            single_page(1, 1)
        }
        if cv_wrap
            setmsg(iso:"Very long lines were split")
        return true
    }

    ; --- saving ---
    ; Send a DOS command (ASCII, e.g. "s:md.tmp") on the command channel.
    sub dos_cmd(uword c) {
        copystr(&iobuf2, c, 50)
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(15, DEVICE, 15)
        void cbm.OPEN()
        cbm.CLOSE(15)
    }

    ; Open file `name` for writing on channel 2, replacing it.
    sub wr_open(uword name) {
        copystr(&iobuf2, iso:"@:", 4)
        appendstr(&iobuf2, name)
        appendstr(&iobuf2, iso:",s,w")
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
    }

    ; Write n bytes at src to channel 2 (in blocks, with MCIOUT).
    sub wr_bytes(uword src, uword n) {
        cbm.CHKOUT(2)
        while n != 0 {
            uword done = 255
            if n < 255
                done = n
            void, done = cx16.MCIOUT(lsb(done), src, false)
            if done == 0
                break
            src += done
            n -= done
        }
        cbm.CLRCHN()
    }

    ; Close channel 2; true if the drive reports "00" (else the status becomes the message).
    sub wr_close() -> bool {
        cbm.CLOSE(2)
        dos_status(&dstat, 40)
        if dstat[0] != iso:'0' or dstat[1] != iso:'0' {
            setmsg(&dstat)
            return false
        }
        return true
    }

    ; Before the backing file changes: pages that only the undo snapshot still uses and that are
    ; read from the file are kept in memory instead (if memory is short, undo is dropped).
    sub pin_snap() {
        uword g = snap_head
        uword f
        if not uvalid
            return
        slots_drop()
        while g != NIL {
            if bget(B_FL, g) == 0 and wget(B_FLN, g) != NIL {
                if wget(B_FR, g) == NIL
                    pg_read(g, pbuf0)
                f = wget(B_FR, g)
                if f == NIL {
                    drop_undo()
                    return
                }
                set_fstate(f, FR_ONLY)
                wset(B_FLN, g, NIL)
            }
            g = snx(g)
        }
    }

    ; The file `name` now holds exactly the document: read pages from it from now on. Every page
    ; in memory becomes a clean copy (so saving frees the memory that changes were using).
    sub rebase(uword name) {
        long pos = 0
        uword g = head
        pin_snap()
        bk_close()
        copystr(&bkname, name, FNLEN)
        while g != NIL {
            uword n = wget(B_BL, g)
            set_foff(g, pos)
            wset(B_FLN, g, n)
            pos += n
            n = wget(B_FR, g)
            if n != NIL
                set_fstate(n, FR_CLEAN)
            g = nx(g)
        }
    }

    ; Write the document to a file, replacing it. Pages that were never loaded are read from the
    ; backing file on the way. When saving over the backing file itself, the document goes to
    ; md.tmp first and is then copied over the old file (which is being read until then).
    sub save_file(uword name) -> bool {
        uword p
        ubyte n
        bool same = bkname[0] != 0 and slen(name) == slen(&bkname) and memeq(name, &bkname, slen(name))
        uword target = name
        if same
            target = iso:"md.tmp"
        flush_all()
        wr_open(target)
        p = head
        while p != NIL {
            slot_load(0, p, 0)
            wr_bytes(pbuf0, s_bl[0])
            p = nx(p)
        }
        slots_drop()                      ; slot 0 was borrowed with made-up line numbers
        if not wr_close()
            return false
        rebase(target)
        if same {
            ; copy md.tmp over the old file (bk_read closes md.tmp at its end)
            wr_open(name)
            bk_open()
            repeat {
                n = bk_read(pbuf0, RAWLEN)
                if n == 0
                    break
                wr_bytes(pbuf0, n)
            }
            bk_close()
            if not wr_close() {
                setmsg(iso:"Save failed! The text is safe in md.tmp")
                return false
            }
            copystr(&bkname, name, FNLEN)
            dos_cmd(iso:"s:md.tmp")
        }
        modified = false
        copystr(&sline, iso:"\"", 1)
        appendstr(&sline, name)
        appendstr(&sline, iso:"\" written")
        setmsg(&sline)
        return true
    }

    ; Load a file and reset cursor and undo; a missing file starts an empty document.
    sub open_file(uword name) {
        copystr(&fname, name, FNLEN)
        if not load_file(name) {
            new_buffer()
        } else {
            cy = 0
            cx = 0
            want = 0
            top = 0
            modified = false
            uvalid = false
            if truncated
                setmsg(iso:"File truncated (too big)!")
            else
                setmsg(iso:"File loaded")
        }
        redraw_all = true
    }

    ubyte[41] sname

    ; Ctrl-W: save, asking for a name first if the document has none.
    sub do_save() {
        if fname[0] == 0 {
            sname[0] = 0
            if not read_line(iso:"Save as: ", &sname, 41) {
                setmsg(iso:"Cancelled")
                return
            }
            if sname[0] == 0
                return
            copystr(&fname, &sname, FNLEN)
        }
        void save_file(&fname)
    }

    ; Guard for open/quit: with unsaved changes the first press only warns; pressing the same
    ; key again (warned) discards the changes.
    sub discard_ok() -> bool {
        if not modified or warned {
            warned = false
            return true
        }
        warned = true
        setmsg(iso:"Unsaved changes! Press the key again to discard them")
        return false
    }

    ; ---------------------------------------------------------------
    ; editing commands
    ; ---------------------------------------------------------------
    ; Called before a typing edit: takes ONE undo snapshot at the start of a typing run
    ; (`typing` stays set until the cursor moves or another command runs).
    sub begin_edit() {
        if not typing {
            snap()
            typing = true
        }
    }

    ; Insert one character at the cursor.
    sub insert_char(ubyte c) {
        begin_edit()
        chbuf[0] = c
        if ed_insert(cy, cx, &chbuf, 1)
            cx++
        set_want()
    }

    ubyte[128] tbuf

    ; Insert constant text at the cursor, leaving the cursor after it. (A "\n" in a Prog8 string is
    ; CR, so CR is converted to a newline here.)
    sub insert_str(uword t) {
        ubyte n = 0
        ubyte i
        ubyte c
        while @(t + n) != 0 and n < 127 {
            c = @(t + n)
            if c == 13
                c = NL
            tbuf[n] = c
            n++
        }
        if not ed_insert(cy, cx, &tbuf, n)
            return
        i = 0
        while i < n {
            if tbuf[i] == NL {
                cy++
                cx = 0
            } else
                cx++
            i++
        }
        set_want()
    }

    ubyte[12] ins

    ; Enter: split the line, keep the indent, and continue '-' '*' '+' '>' list/quote markers;
    ; Enter on an empty item removes the marker (ends the list).
    sub do_newline() {
        ubyte n = 1
        ubyte i = 0
        uword sl = lp(cy)
        uword ln = linelen(cy)
        begin_edit()
        ins[0] = NL
        while i < ln and @(sl + i) == SP and i < 8 {
            ins[n] = @(sl + i)
            n++
            i++
        }
        if i + 1 < ln and @(sl + i + 1) == SP and cx >= (i as uword) + 2 and
           (@(sl + i) == iso:'-' or @(sl + i) == iso:'*' or @(sl + i) == iso:'+' or @(sl + i) == iso:'>') {
            if ln == (i as uword) + 2 {               ; empty item: end the list
                del_chars(cy, 0, ln)
                cx = 0
                set_want()
                return
            }
            ins[n] = @(sl + i)
            n++
            ins[n] = SP
            n++
        }
        if ed_insert(cy, cx, &ins, n) {
            cy++
            cx = n - 1
        }
        set_want()
    }

    ; Delete the character before the cursor (joins lines at column 0).
    sub backspace() {
        uword n
        begin_edit()
        if cx > 0 {
            cx--
            del_chars(cy, cx, 1)
        } else if cy > 0 {
            n = linelen(cy - 1)
            if join_next(cy - 1) {
                cy--
                cx = n
            }
        }
        set_want()
    }

    ; Ctrl-U: delete the current line.
    sub kill_line() {
        snap()
        typing = false
        if nlines == 1 {
            del_chars(0, 0, linelen(0))
        } else {
            del_line(cy)
            if cy >= nlines
                cy = nlines - 1
        }
        cx = 0
        clamp_cx()
        set_want()
    }

    ; Insert a marker pair such as **** and put the cursor `back` characters from the end,
    ; i.e. between the two halves (Ctrl-B bold, Ctrl-E italic, Ctrl-K code).
    sub pair_insert(uword t, ubyte back) {
        snap()
        typing = false
        insert_str(t)
        cx -= back
        set_want()
    }

    ; Ctrl-A: insert a 3-column table template and put the cursor in the first header cell.
    sub insert_table() {
        snap()
        typing = false
        if linelen(cy) > 0 {
            cx = linelen(cy)
            insert_str(iso:"\n\n")
        } else
            cx = 0
        insert_str(iso:"| Column A | Column B | Column C |\n")
        insert_str(iso:"|:---------|:--------:|---------:|\n")
        insert_str(iso:"| one      | two      | three    |\n")
        cy -= 3
        cx = 2
        set_want()
        setmsg(iso:"Table inserted - edit the cells, Ctrl-P to preview")
    }

    ; Ctrl-R: insert a [TOC] marker on its own line.
    sub insert_toc_marker() {
        snap()
        typing = false
        if linelen(cy) > 0 {
            cx = linelen(cy)
            insert_str(iso:"\n\n")
        } else
            cx = 0
        insert_str(iso:"[TOC]\n\n")
        set_want()
        setmsg(iso:"[TOC] marker inserted - shown as contents in the preview")
    }

    ubyte[32] pat

    ; Ctrl-F: prompt for text and jump to the next match, wrapping; Enter on an empty prompt
    ; repeats the previous search. Plain text, case-sensitive.
    sub do_find() {
        uword l
        uword i
        uword pl
        uword n
        uword s
        uword stop
        uword c0
        uword cnt = 0
        ubyte first
        copystr(&pat, &lastsearch, 31)
        if not read_line(iso:"Find: ", &pat, 32) {
            msg[0] = 0
            return
        }
        if pat[0] != 0
            copystr(&lastsearch, &pat, 31)
        pl = slen(&lastsearch)
        if pl == 0
            return
        first = lastsearch[0]
        l = cy
        c0 = cx + 1
        ; look at every line once, wrapping; the start line is revisited (up to the cursor) at the end
        while cnt <= nlines {
            n = linelen(l)
            s = lp(l)
            if cnt == nlines
                stop = cx + pl
            else
                stop = n
            if stop > n
                stop = n
            i = c0
            while i + pl <= stop {
                if @(s + i) == first and memeq(s + i, &lastsearch, pl) {
                    cy = l
                    cx = i
                    set_want()
                    setmsg(iso:"Found")
                    return
                }
                i++
            }
            l++
            if l >= nlines
                l = 0
            c0 = 0
            cnt++
        }
        setmsg(iso:"Not found")
    }

    ; Move the cursor to the start of heading i (from the contents menu).
    sub goto_heading(ubyte i) {
        cy = hl[i]
        cx = 0
        top = cy
        set_want()
        redraw_all = true
    }

    ubyte[41] oname

    ; Handle one key in the editor. Printable characters are inserted. The first `when` handles
    ; typing keys (these keep an undo run going); the second handles movement and commands,
    ; which end the run: arrows, Home/End, paging, preview, contents, save, open, quit, undo,
    ; kill line, find, markup shortcuts, table and [TOC] inserts, and help.
    sub edit_key(ubyte k) {
        ubyte i
        ubyte t

        if not (k == CTRL_X or k == K_F8 or k == CTRL_O or k == K_F3)
            warned = false
        if k >= 32 and k < 127 {
            insert_char(k)
            return
        }
        when k {
            13, 10 -> {
                do_newline()
                return
            }
            K_BKSP, $08, $7f -> {
                backspace()
                return
            }
            K_DEL -> {
                begin_edit()
                if cx < linelen(cy)
                    del_chars(cy, cx, 1)
                else if cy + 1 < nlines
                    void join_next(cy)
                return
            }
            TAB -> {
                begin_edit()
                insert_char(SP)
                insert_char(SP)
                return
            }
        }
        typing = false
        when k {
            K_LEFT -> {
                if cx != 0
                    cx--
                else if cy != 0 {
                    cy--
                    cx = linelen(cy)
                }
                set_want()
            }
            K_RIGHT -> {
                if cx < linelen(cy)
                    cx++
                else if cy + 1 < nlines {
                    cy++
                    cx = 0
                }
                set_want()
            }
            K_UP -> move_up()
            K_DOWN -> move_down()
            K_HOME -> {
                cx = 0
                set_want()
            }
            K_END -> {
                cx = linelen(cy)
                set_want()
            }
            K_F6 -> {
                i = 0
                while i < textrows - 1 {
                    move_up()
                    i++
                }
            }
            K_F7 -> {
                i = 0
                while i < textrows - 1 {
                    move_down()
                    i++
                }
            }
            CTRL_P, K_F5 -> preview_mode()
            CTRL_G, K_F4 -> {
                t = toc_menu()
                redraw_all = true
                if t != 255
                    goto_heading(t)
            }
            CTRL_W, K_F2 -> do_save()
            CTRL_O, K_F3 -> {
                if discard_ok() {
                    oname[0] = 0
                    if read_line(iso:"Open file: ", &oname, 41) and oname[0] != 0
                        open_file(&oname)
                }
            }
            CTRL_X, K_F8 -> {
                if discard_ok()
                    quit = true
            }
            CTRL_Z -> do_undo()
            CTRL_U -> kill_line()
            CTRL_F -> do_find()
            CTRL_B -> pair_insert(iso:"****", 2)
            CTRL_E -> pair_insert(iso:"**", 1)
            CTRL_K -> pair_insert(iso:"``", 1)
            CTRL_A -> insert_table()
            CTRL_R -> insert_toc_marker()
            K_F1 -> show_help()
        }
    }

    ; Main loop: redraw, read a key, clear the message, run the key.
    sub editor() {
        ubyte k
        redraw_all = true
        while not quit {
            refresh()
            k = getkey()
            msg[0] = 0
            edit_key(k)
        }
    }

        ubyte[41] argbuf

    ; Startup file hand-off used by `make run FILE=name`: if a small file called MD.ARG exists
    ; on the drive, its first line is a file name to open at start-up. Normally it does not
    ; exist, and this does nothing. Returns true (name in argbuf) if a name was read.
    sub startup_arg() -> bool {
        ubyte n = 0
        ubyte c
        ubyte stt
        cbm.SETNAM(10, "md.arg,s,r")
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        void cbm.CHKIN(2)
        repeat {
            c = cbm.CHRIN()
            stt = cbm.READST()
            if stt & $bf != 0
                break
            if c == 13 or c == 10
                break
            if n < FNLEN {
                argbuf[n] = c
                n++
            }
            if stt & $40 != 0
                break
        }
        argbuf[n] = 0
        cbm.CLRCHN()
        cbm.CLOSE(2)
        dos_status(&dstat, 40)          ; also clears the drive's error light if the file was missing
        return n != 0
    }

;@SELFTEST-SUBS

    ; Program entry: set up screen, ISO mode and fonts, run the editor, then restore the standard
    ; PETSCII character set and console on exit (we modified the font).
    sub start() {
        bool opened
        sys.memset($0400, $0400, 0)      ; golden RAM holds buffers too (see pls): start them empty
        init_screen()
        cbm.CHROUT($0f)              ; ISO mode
        build_fonts()
        clear_screen()
        cx16.VERA_CTRL &= $fe
        cx16.VERA_DC_BORDER = 0
        nbanks = cx16.numbanks()
        s_buf[0] = pbuf0
        s_buf[1] = pbuf1
        s_ls[0] = pls0
        s_ls[1] = pls1
        new_buffer()
        fname[0] = 0
        msg[0] = 0
        ;@SELFTEST-INIT
        opened = startup_arg()
        if opened
            open_file(&argbuf)
        if not opened
            setmsg(iso:"MD for X16 - F1 help, Ctrl-O open, Ctrl-P preview")
        editor()
        cbm.CHROUT($8f)              ; ISO mode off
        cx16.screen_set_charset(3, 0)    ; restore the standard PETSCII charset (we edited glyphs)
        cbm.CHROUT($93)              ; clear screen
    }
}
