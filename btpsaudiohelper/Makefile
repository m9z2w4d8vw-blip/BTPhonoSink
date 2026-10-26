THEOS_PACKAGE_SCHEME ?= rootless
GO_EASY_ON_ME = 1
ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
TOOL_NAME = BTPSAudioHelper
BTPSAudioHelper_FILES = main.m BTPSIPCProtocol.c BTPSV75RTP.c BTPSMedia.c sbc_decode.c
BTPSAudioHelper_CFLAGS = -fobjc-arc -I..
BTPSAudioHelper_FRAMEWORKS = Foundation AVFoundation
BTPSAudioHelper_INSTALL_PATH = /usr/bin
include $(THEOS_MAKE_PATH)/tool.mk
