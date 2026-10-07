# Agent core (C).
#
#   make              optimized build      -> build/release/magent-agent
#   make debug        ASan + UBSan build   -> build/debug/magent-agent
#   make run-daemon   overlay in daemon mode driving this agent (dev account only, see CLAUDE.md)
#   make clean

CC    := clang
MODE  ?= release
BUILD := build/$(MODE)
BIN   := $(BUILD)/magent-agent

SRCS := $(wildcard *.c)
OBJS := $(SRCS:%.c=$(BUILD)/%.o)
DEPS := $(OBJS:.o=.d)

# -MMD -MP: track header dependencies so editing a .h rebuilds what includes it.
CFLAGS := -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes \
          -Werror=implicit-function-declaration -MMD -MP
LDFLAGS :=
# macOS frameworks go here when the platform layer lands, e.g. -framework ApplicationServices
LDLIBS :=

ifeq ($(MODE),debug)
  CFLAGS  += -O0 -g -fsanitize=address,undefined -fno-omit-frame-pointer
  LDFLAGS += -fsanitize=address,undefined
else
  CFLAGS  += -O2 -g
endif

OVERLAY_DIR := ../overlay
OVERLAY     := $(OVERLAY_DIR)/.build/debug/magent-overlay

.PHONY: all debug clean run-daemon

all: $(BIN)

# Separate build dirs per mode, so release and sanitizer objects never get linked together.
debug:
	$(MAKE) MODE=debug

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $@

# ⌃⌥⌘Space sends a request, ⌃⌥⌘K kills the agent, Ctrl-C here stops both.
run-daemon: $(BIN)
	cd $(OVERLAY_DIR) && swift build
	$(OVERLAY) --daemon $(abspath $(BIN))

clean:
	rm -rf build

-include $(DEPS)
