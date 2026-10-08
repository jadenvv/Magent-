# Agent core (C).
#
#   make              optimized build      -> build/release/magent-agent
#   make debug        ASan + UBSan build   -> build/debug/magent-agent
#   make test         build and run the tests in tests/
#   make run-daemon   overlay in daemon mode driving this agent (dev account only, see CLAUDE.md)
#   make clean

CC    := clang
MODE  ?= release
BUILD := build/$(MODE)
BIN   := $(BUILD)/magent-agent

# Core (C) at the top level; macOS-specific code (Objective-C) behind platform/*.h.
SRCS          := $(wildcard *.c)
PLATFORM_SRCS := $(wildcard platform/macos/*.m)
PLATFORM_OBJS := $(PLATFORM_SRCS:%.m=$(BUILD)/%.o)
OBJS          := $(SRCS:%.c=$(BUILD)/%.o) $(PLATFORM_OBJS)

TEST_SRCS := $(wildcard tests/*.c)
TEST_BINS := $(TEST_SRCS:%.c=$(BUILD)/%)

DEPS := $(OBJS:.o=.d) $(TEST_SRCS:%.c=$(BUILD)/%.d)

# macOS 14 is the floor for ScreenCaptureKit's screenshot API (and matches the overlay).
MACOS_MIN := -mmacosx-version-min=14.0

ifeq ($(MODE),debug)
  OPT     := -O0 -g -fsanitize=address,undefined -fno-omit-frame-pointer $(MACOS_MIN)
  LDFLAGS := -fsanitize=address,undefined $(MACOS_MIN)
else
  OPT     := -O2 -g $(MACOS_MIN)
  LDFLAGS := $(MACOS_MIN)
endif

# -MMD -MP: track header dependencies so editing a .h rebuilds what includes it.
CPPFLAGS  := -Iplatform -MMD -MP
WARN      := -Wall -Wextra -Wshadow -Werror=implicit-function-declaration
CFLAGS    := -std=c17 $(WARN) -Wpedantic -Wstrict-prototypes $(OPT)
# No -Wpedantic here: Apple's framework headers aren't pedantic-clean.
OBJCFLAGS := -fobjc-arc $(WARN) $(OPT)
LDLIBS    := -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
             -framework ImageIO -framework ScreenCaptureKit -framework Vision -framework ApplicationServices

OVERLAY_DIR := ../overlay
OVERLAY     := $(OVERLAY_DIR)/.build/debug/magent-overlay

.PHONY: all debug test clean run-daemon

all: $(BIN)

# Separate build dirs per mode, so release and sanitizer objects never get linked together.
debug:
	$(MAKE) MODE=debug

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) -c $< -o $@

# Each tests/foo.c is its own program, linked against the platform layer only (not main.c).
$(BUILD)/tests/%: $(BUILD)/tests/%.o $(PLATFORM_OBJS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

# Keep test objects; otherwise make deletes them as intermediates and recompiles every run.
.SECONDARY: $(TEST_SRCS:%.c=$(BUILD)/%.o)

test: $(TEST_BINS)
	@for t in $(TEST_BINS); do echo "== $$t"; $$t || exit 1; done

# ⌃⌥⌘Space sends a request, ⌃⌥⌘K kills the agent, Ctrl-C here stops both.
run-daemon: $(BIN)
	cd $(OVERLAY_DIR) && swift build
	$(OVERLAY) --daemon $(abspath $(BIN))

clean:
	rm -rf build

-include $(DEPS)
