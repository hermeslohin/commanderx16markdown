# MD - Markdown editor for the Commander X16

A modeless Markdown editor written in [Prog8](https://prog8.readthedocs.io/). Write in the editor, press **Ctrl-P** (or **F5**) and the
document is shown rendered with fonts, titles, tables and a table of contents. Press it again to go back.

## Build / run

Needs the [Prog8](https://github.com/irmen/prog8/releases) compiler (`prog8c-12.x-all.jar`, needs Java; put it at
`~/prog8c.jar` or set `PROG8C`) and the x16emu emulator (paths at the top of the `Makefile`).
A prebuilt `MD.PRG` is included.

    make          # -> MD.PRG
    make run      # starts x16emu with this folder as the SD card
    make run FILE=DEMO.MD   # ...and opens that file (then Ctrl-P for the preview)

On the X16: `LOAD "MD.PRG"` then `RUN`. Try the included `DEMO.MD`: `make run FILE=DEMO.MD`, or press `Ctrl-O`, type `demo.md` (lower case), Enter, then `Ctrl-P`.

## Keys

| key                | action                                                      |
|--------------------|-------------------------------------------------------------|
| `Ctrl-P` / `F5`    | **toggle preview** (also `Esc` inside the preview)          |
| `Ctrl-G` / `F4`    | **table of contents**: pick a heading and jump to it        |
| `Ctrl-W` / `F2`    | save (asks for a name if the document has none)             |
| `Ctrl-O` / `F3`    | open a file                                                 |
| `Ctrl-X` / `F8`    | quit (press twice to discard unsaved changes)               |
| `F1`               | help                                                        |
| `Ctrl-B` `Ctrl-E` `Ctrl-K` | insert `**bold**`, `*italic*`, `` `code` `` with the cursor inside |
| `Ctrl-A`           | insert a table template                                     |
| `Ctrl-R`           | insert a `[TOC]` marker                                     |
| `Ctrl-Z`           | undo (one level; press again to redo)                       |
| `Ctrl-U`           | delete the current line                                     |
| `Ctrl-F`           | find (Enter on an empty prompt repeats the last search)     |
| arrows, Home, End  | move; `F6` / `F7` = page up / page down                     |

Enter continues `-`, `*`, `+` lists and `>` quotes; pressing Enter on an empty item ends the list.

In the preview: `Up`/`Down` scroll, `Space`/`F7` and `b`/`F6` page, `n`/`p` next/previous heading,
`Home`/`End`, `F4` (or `t`) contents menu, `Esc` / `Ctrl-P` back to the editor.

## What the preview renders

* **Fonts** - at start-up the editor builds *bold* and *italic* faces from the ISO character set and stores
  them in the unused upper half of VERA's character memory, so bold/italic are real glyph shapes, not just colours.
  Headings are bold and coloured per level (`#` to `######`); `#` and `##` also get a rule underneath.
  Setext headings (`Title` + `====` / `----`) work too.
* **Inline** - `**bold**`, `__bold__`, `*italic*`, `_italic_`, `` `code` ``, `~~strike~~`, `[links](url)`, `![images](url)`
  (shown in colour with the URL hidden), backslash escapes.
* **Blocks** - paragraphs (word wrapped), `-`/`*`/`+` and `1.` lists (nested by indent), `>` quotes (nestable),
  `---` rules, fenced code blocks, and **tables** (`|` with a `---` separator row, `:--` `:-:` `--:` alignment)
  drawn with box-drawing characters. Wide tables shrink their widest columns to fit the screen.
* **Table of contents** - a line containing only `[TOC]` becomes a linked-free contents list of all headings in the
  preview. `Ctrl-G` / `F4` gives a jump menu in both the editor and the preview.

The editor itself colours headings, bold/italic/code, links, lists, quotes, tables and code fences, and wraps long
lines on screen.

## Limits

* **Large files.** A file is not read into memory when it is opened: it is scanned once and cut into 1 KB pages,
  and each page is read from the file when you get to it (scrolling, jumping, searching) and cached in banked
  RAM. Unchanged pages are dropped from the cache whenever room is needed, so a file can be much larger than
  memory: up to **65,000 lines** or about **3.5 MB** (whichever comes first), even on a 512 KB X16. Files with more lines are truncated on load.
* **Changed pages stay in memory** until you save. `Free` on the status line is the room left for them (in KB);
  if it runs out you get `Memory full of changes: save (Ctrl-W) to free it`, and saving makes all of it free
  again. Since pages are read back from the file while you work, do not change the file behind MD's back.
* Saving over the file that is open writes `md.tmp` first and then copies it over the file (so the old text can be
  read until the end); if that copy fails, your text is still in `md.tmp`. Paging needs the X16's SD card / host
  file system (CMDR-DOS, which can seek in a file).
* Line endings: CR, LF and CRLF are read (and saved as LF). Lines longer than 700 characters are split when
  loading (and cannot be typed longer). Run the emulator with `-ram 2048` (the Makefile does) for the biggest cache.
* The preview is rendered into banked RAM above the changed pages (51 rows per bank); if the document is so big
  that it does not fit, the preview shows `(too long: end cut off)`.
* One undo level (page-based, so it also covers multi-line edits). Tables: up to 8 columns. Headings tracked for the contents: 100.
* ASCII only (ISO mode); other bytes show as `?`.

## Notes

* The control-key bindings assume the X16 keyboard delivers `Ctrl-<letter>` as codes 1-26 in ISO mode. The
  function keys (`F1`-`F8`) give the same commands for save, open, quit, preview and contents, in case a key
  combination is not delivered by your keyboard / host.
* `Ctrl-S`, `Ctrl-T`, `Ctrl-Q` and `Ctrl-H` are not used: on the X16 they are the same codes as Home, Backspace,
  Cursor-down and Backspace.

## Self test

`./runtest.sh '<keys>' [rows]` builds a variant that feeds scripted keystrokes (`\x10` = Ctrl-P, `\r` = Enter), dumps
the VERA text screen to `tests/scr.out` and prints it with the bold/italic/box glyphs mapped back to plain characters.
`FILE=name ./runtest.sh ...` chooses the preloaded file from `tests/` (default `test.md`). It uses `~/prog8c.jar`
unless `PROG8C` is set.
The keys (at most 254) are passed in `tests/keys.in`. `RAM=256 ./runtest.sh ...` runs the emulator with less banked
RAM (default 2048), which makes the page cache small, so large files are really read back from disk as you move.

    ./runtest.sh '\x10'                      # preview of tests/test.md
    ./runtest.sh '\x8a\x11\x11\r'            # open the TOC menu, go down twice, jump
