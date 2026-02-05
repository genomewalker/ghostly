PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
BUILD_DIR = .build
BINARY = $(BUILD_DIR)/ghostly
SOURCES = main.swift IPCClient.swift

SWIFTC = swiftc
SWIFTFLAGS = -O -whole-module-optimization

.PHONY: all clean install uninstall

all: $(BINARY)

$(BINARY): $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -o $(BINARY) $(SOURCES)
	@echo "Built: $(BINARY)"

clean:
	rm -rf $(BUILD_DIR)

install: $(BINARY)
	@mkdir -p $(INSTALL_DIR)
	cp $(BINARY) $(INSTALL_DIR)/ghostly
	@echo "Installed: $(INSTALL_DIR)/ghostly"

uninstall:
	rm -f $(INSTALL_DIR)/ghostly
	@echo "Removed: $(INSTALL_DIR)/ghostly"
