TARGET := iphone:clang:16.5:14.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BTPhonoSink

BTPhonoSink_FILES  = Tweak.xm SBCSink.mm sbc_decode.c
BTPhonoSink_CFLAGS = -fobjc-arc -fvisibility=hidden
BTPhonoSink_CCFLAGS = -std=c++17 -fobjc-arc -fvisibility=hidden
BTPhonoSink_FRAMEWORKS = AVFoundation AudioToolbox CoreAudio Foundation
BTPhonoSink_LDFLAGS = -Wl,-rpath,/usr/lib

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 bluetoothd"
