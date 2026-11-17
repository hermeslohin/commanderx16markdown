# Build with the Prog8 compiler (a Java program): download prog8c-12.x-all.jar from
# https://github.com/irmen/prog8/releases and put it at ~/prog8c.jar, or override PROG8C:
#     make PROG8C="java -jar /path/to/prog8c.jar"
PROG8C = java -jar $(HOME)/prog8c.jar
X16    = /usr/local/x16emu/x16emu
ROM    = /usr/local/x16emu/rom.bin

all: MD.PRG

# prog8c writes md.prg; copy it to MD.PRG (the build goes in its own folder so that
# case-insensitive file systems do not confuse the two names)
MD.PRG: md.p8
	mkdir -p p8build && $(PROG8C) -target cx16 -out p8build md.p8
	cp p8build/md.prg $@

# `make run` starts the emulator with this folder as the SD card.
# `make run FILE=name` also opens that file: the name (lower-cased, which is how the X16
# wants it) goes into MD.ARG, which the program reads at start-up; it is removed afterwards.
run: MD.PRG
	@if [ -n "$(FILE)" ]; then echo "$(FILE)" | tr 'A-Z' 'a-z' > MD.ARG; fi; \
	$(X16) -ram 2048 -rom $(ROM) -fsroot $(CURDIR) -prg MD.PRG -run; rm -f MD.ARG

clean:
	rm -rf p8build build_test
	rm -f MD.PRG MD.ARG
