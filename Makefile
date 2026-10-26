# BTPhonoSink - bluetoothd tweak for rootless jailbreaks (Dopamine / ElleKit)

# Rootless: files install under /var/jb and the package architecture becomes iphoneos-arm64.
# Rootful build instead:  make package THEOS_PACKAGE_SCHEME=
THEOS_PACKAGE_SCHEME ?= rootless

# Do not turn compiler warnings into build failures.
# MUST stay above the 'include .../common.mk' line: it is read while that file loads.
GO_EASY_ON_ME = 1

# bluetoothd is an arm64e binary: without an arm64e slice this dylib builds fine and never loads.
# iOS 15 is the deployment target Theos recommends for rootless (theos.dev/docs/rootless).
ARCHS  := arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BTPhonoSink

BTPhonoSink_FILES      = Tweak.xm BTPSLog.c BTPSCore.c BTPSDiagnostics.c BTPSIPCProtocol.c BTPSDaemonProbe.c BTPSV74Tone.c BTPSV75Fixture.c SBCSink.mm sbc_decode.c BTPSMedia.c
BTPhonoSink_CFLAGS     = -fobjc-arc -fvisibility=hidden -fblocks
BTPhonoSink_CCFLAGS    = -std=c++17 -fobjc-arc -fvisibility=hidden
BTPhonoSink_FRAMEWORKS = AVFoundation AudioToolbox CoreAudio CoreFoundation Foundation
BTPhonoSink_LIBRARIES  = substrate

include $(THEOS)/makefiles/tweak.mk

# The Settings > Tweaks page with the debug log (folder btphonosinkprefs/).
# If it ever fails to build, set this to 0 (or run: make package BTPS_WITH_PREFS=0) and the tweak still builds.
BTPS_WITH_PREFS ?= 1
# The auxiliary diagnostic executable never runs inside bluetoothd.
BTPS_WITH_IPC_HELPER ?= 1
ifeq ($(BTPS_WITH_IPC_HELPER),1)
SUBPROJECTS += btpsaudiohelper
endif
ifeq ($(BTPS_WITH_PREFS),1)
SUBPROJECTS += btphonosinkprefs
endif

# The helper and optional Settings bundle participate in the same package.
ifneq ($(strip $(SUBPROJECTS)),)
include $(THEOS_MAKE_PATH)/aggregate.mk
endif
