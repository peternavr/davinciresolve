# Fairlight capture fix for DaVinci Resolve on PipeWire
CC      ?= gcc
CFLAGS  ?= -shared -fPIC -O2 -Wall
SRC      = src/resolve-alsa-shim.c
OUT      = resolve-alsa-shim.so

.PHONY: all debug install uninstall diagnose clean

all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< -ldl

# Adds the flight recorder and tees Fairlight's internal debug() logger.
# Enable output at runtime with RESOLVE_ALSA_SHIM_LOG=1
debug: $(SRC)
	$(CC) $(CFLAGS) -Wno-format -DSHIM_DEBUG_TEE -o $(OUT) $< -ldl

install:
	@./install.sh

uninstall:
	@./install.sh --uninstall

diagnose:
	@./diagnose.sh

clean:
	rm -f $(OUT)
