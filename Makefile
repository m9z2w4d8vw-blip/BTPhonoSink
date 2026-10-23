# BTPhonoSink - bluetoothd tweak for rootless jailbreaks (Dopamine / ElleKit)

# Rootless: files install under /var/jb and the package architecture becomes iphoneos-arm64.
# Rootful build instead:  make package THEOS_PACKAGE_SCHEME=
THEOS_PACKAGE_SCHEME ?= rootless

# bluetoothd is an arm64e binary: without an arm64e slice this dylib builds fine and never loads.
# iOS 15 is the deployment target Theos recommends for rootless (theos.dev/docs/rootless).
ARCHS  := arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BTPhonoSink

BTPhonoSink_FILES      = Tweak.xm SBCSink.mm sbc_decode.c
BTPhonoSink_CFLAGS     = -fobjc-arc -fvisibility=hidden
BTPhonoSink_CCFLAGS    = -std=c++17 -fobjc-arc -fvisibility=hidden
BTPhonoSink_FRAMEWORKS = AVFoundation AudioToolbox CoreAudio Foundation
BTPhonoSink_LIBRARIES  = substrate

include $(THEOS)/makefiles/tweak.mk
