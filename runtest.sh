#!/bin/sh
# usage: runtest.sh 'keys' [rows]   keys use python-style escapes ('\x10' = Ctrl-P, '\r' = Enter)
# Builds a self-test copy of md.p8 that feeds scripted keys (tests/<FILE> is preloaded, default test.md),
# dumps the VERA text screen to tests/scr.out and prints it with bold/italic/box glyphs mapped to plain chars.
# PROG8C=path/to/prog8c.jar (default ~/prog8c.jar)
cd "$(dirname "$0")"
J=${PROG8C:-$HOME/prog8c.jar}
mkdir -p build_test
FILE=${FILE:-test.md} python3 - "$1" <<'PY'
import sys, os
keys=sys.argv[1].encode().decode('unicode_escape')
assert len(keys) < 255, 'at most 254 keys'
open('tests/keys.in','wb').write(keys.encode('latin1')+b'\0')
s=open('md.p8').read()
s=s.replace(';@SELFTEST-HOOK','''k = bget(B_FRM, $1900 + selfk)
        if k != 0 {
            selfk++
            return k
        }
        selftest_dump()''')
s=s.replace(';@SELFTEST-SUBS','''uword selfk
    ; the keys come from tests/keys.in (written by this script), kept in bank B_FRM at $b900
    sub selftest_load() {
        cbm.SETNAM(7, "keys.in")
        cbm.SETLFS(4, 8, 4)
        void cbm.OPEN()
        void cbm.CHKIN(4)
        cx16.rambank(B_FRM)
        void cx16.MACPTR(255, $b900, false)
        cx16.rambank(0)
        cbm.CLRCHN()
        cbm.CLOSE(4)
    }
    sub selftest_dump() {
        ubyte y
        cbm.SETNAM(13, "@:scr.out,s,w")
        cbm.SETLFS(3, 8, 3)
        void cbm.OPEN()
        cbm.CHKOUT(3)
        for y in 0 to scrh-1 {
            vera_at(0, y)
            repeat 160
                cbm.CHROUT(cx16.VERA_DATA0)
        }
        cbm.CLRCHN()
        cbm.CLOSE(3)
        @($9fb5) = 1
        repeat { }
    }''')
s=s.replace(';@SELFTEST-INIT','selftest_load()\n        open_file(iso:"%s")'%os.environ['FILE'])
open('build_test/mdt.p8','w').write(s)
PY
rm -f build_test/mdt.prg tests/scr.out tests/SCR.OUT
(cd build_test && java -jar "$J" -target cx16 mdt.p8 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "ERROR|error")
[ -f build_test/mdt.prg ] || { echo "build failed"; exit 1; }
(/usr/local/x16emu/x16emu -ram ${RAM:-2048} -rom /usr/local/x16emu/rom.bin -fsroot tests -prg build_test/mdt.prg -run -warp >emu.log 2>&1 &)
for i in $(seq 1 ${WAIT:-20}); do sleep 1; [ -s tests/scr.out ] && sleep 3 && break; done
pkill x16emu
python3 - "${2:-60}" <<'PY'
import sys
n=int(sys.argv[1])
b=open('tests/scr.out','rb').read()     # rows of 80 x (character, colour)
G={27:'-',28:'|',29:'+',30:'+',31:'+',127:'+',154:'+',155:'+',156:'+',157:'+',158:'+',159:'*'}
def f(c):
    if c>=160 and c!=255 and c not in G: c-=128      # bold face -> plain
    if 128<=c<=153: c=ord('a')+c-128                  # italic face -> plain
    if 1<=c<=26: c=ord('A')+c-1
    return G.get(c,chr(c)) if (c>=127 or c<32) else chr(c)
for r in range(min(n,len(b)//160)):
    print('%2d|%s'%(r,''.join(f(c) for c in b[r*160:r*160+160:2]).rstrip()))
PY
