# Settings > Tweaks page for BTPhonoSink. Built as a subproject of the main Makefile.
THEOS_PACKAGE_SCHEME ?= rootless
GO_EASY_ON_ME = 1

# Settings (Preferences.app) is an arm64e process on these devices: an arm64-only bundle would silently fail to load.
ARCHS  := arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BTPhonoSinkPrefs

BTPhonoSinkPrefs_FILES      = BTPSRootListController.m BTPSLogViewController.m BTPSLogReader.m
BTPhonoSinkPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
BTPhonoSinkPrefs_CFLAGS     = -fobjc-arc -I..
# Preferences.framework is private and not in the Xcode SDK: resolve PSListController at runtime instead of link time.
BTPhonoSinkPrefs_LDFLAGS    = -Wl,-undefined,dynamic_lookup
BTPhonoSinkPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
