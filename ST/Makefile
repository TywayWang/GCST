.PHONY: all build run stop clean

all: build

build:
	@chmod +x build.sh
	@./build.sh

run: build
	@echo "Starting ST..."
	@open ST.app

stop:
	@echo "Stopping ST..."
	@pkill -f "ST.app/Contents/MacOS/ST" || true

clean:
	@rm -rf build bin ST.app
