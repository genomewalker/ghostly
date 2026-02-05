CXX ?= g++
CXXFLAGS ?= -O2 -Wall -Wextra -std=c++11

# macOS: forkpty is in libSystem, no -lutil needed
# Linux: forkpty is in libutil
ifeq ($(shell uname -s),Darwin)
  LDFLAGS ?=
else
  LDFLAGS ?= -lutil
endif

PREFIX ?= $(HOME)/.local

.PHONY: all clean install

all: ghostly-session

ghostly-session: ghostly-session.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

install: ghostly-session
	mkdir -p $(PREFIX)/bin
	cp ghostly-session $(PREFIX)/bin/ghostly-session
	chmod 755 $(PREFIX)/bin/ghostly-session

clean:
	rm -f ghostly-session
