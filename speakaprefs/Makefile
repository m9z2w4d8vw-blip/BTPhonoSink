# Settings > Tweaks page for Speaka. Built as a subproject of the main Makefile.
THEOS_PACKAGE_SCHEME ?= rootless
GO_EASY_ON_ME = 1

# Settings (Preferences.app) is an arm64e process on these devices: an arm64-only bundle would silently fail to load.
ARCHS  := arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SpeakaPrefs

SpeakaPrefs_FILES      = BTPSRootListController.m BTPSLogViewController.m BTPSLogReader.m BTPSAudioProbe.m BTPSIPCSender.m BTPSIPCProtocol.c
SpeakaPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation AVFoundation AVKit
SpeakaPrefs_CFLAGS     = -fobjc-arc -I..
# Preferences.framework is private and not in the Xcode SDK: resolve PSListController at runtime instead of link time.
SpeakaPrefs_LDFLAGS    = -Wl,-undefined,dynamic_lookup
SpeakaPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
