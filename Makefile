CLANG := xcrun clang
CFLAGS := -fobjc-arc -O2 -Wall -Wextra -arch arm64 -arch x86_64
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all clean test-artwork-diagnostics test-move-backup

all: build/device_helper build/airtraffic_host

build:
	mkdir -p $@

build/device_helper: Sources/device_helper.m Sources/airlift_target.h | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

build/airtraffic_host: Sources/airtraffic_host.m | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) $< -o $@
	codesign --force --sign - $@

build/artwork_read_diagnostics_test: tests/artwork_read_diagnostics_test.m Sources/device_helper.m Sources/airlift_target.h | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@

test-artwork-diagnostics: build/artwork_read_diagnostics_test
	./build/artwork_read_diagnostics_test

build/move_backup_native_test: tests/move_backup_native_test.m Sources/device_helper.m Sources/airlift_target.h | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@

test-move-backup: build/move_backup_native_test
	./build/move_backup_native_test

clean:
	rm -rf build
