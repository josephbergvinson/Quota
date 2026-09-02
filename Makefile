DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
CONFIGURATION ?= debug

.PHONY: install build test app run dev clean

install:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" ./Scripts/install.sh

build:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" swift build -c "$(CONFIGURATION)"

test:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test

app:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" ./Scripts/build-app.sh "$(CONFIGURATION)"

run:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" ./Scripts/build-app.sh "$(CONFIGURATION)" --open

dev:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" swift run Quota

clean:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" swift package clean
