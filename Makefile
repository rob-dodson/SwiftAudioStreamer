SWIFTC := swiftc
MODULE_CACHE := /tmp/swift-module-cache
TARGET := swift-audio-streamer
SOURCES := \
	AudioStreamSupport.swift \
	AudioStream.swift \
	InputStream.swift \
	AudioQueue.swift \
	HarnessSupport.swift \
	StreamHarness.swift \
	main.swift

.PHONY: all run clean typecheck

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(SWIFTC) -module-cache-path $(MODULE_CACHE) $(SOURCES) -o $(TARGET)

run: $(TARGET)
	./$(TARGET) $(URL)

typecheck: $(SOURCES)
	$(SWIFTC) -typecheck -module-cache-path $(MODULE_CACHE) $(SOURCES)

clean:
	rm -f $(TARGET)
