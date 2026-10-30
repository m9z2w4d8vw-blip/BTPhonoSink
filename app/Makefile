# Speaka: the companion app for the BTPhonoSink tweak, packaged for TrollStore (.tipa).
#
#   make -C app tipa FINALPACKAGE=1    ->  app/packages/Speaka.tipa
#
# Independent of the tweak's Makefile at the repository root: it never goes into the tweak's .deb.

TARGET := iphone:clang:latest:15.0
ARCHS := arm64
# Do not turn compiler warnings into build failures (the UI code uses deprecated-but-working keyWindow).
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Speaka

Speaka_FILES = $(wildcard Speaka/*.m) $(wildcard Speaka/Model/*.m) $(wildcard Speaka/UI/*.m) $(wildcard Speaka/UI/Transition/*.m)
Speaka_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics QuartzCore AVFoundation
# -I.. finds BTPSShared.h at the repository root: the same preference keys and notification names as the tweak.
Speaka_CFLAGS = -fobjc-arc -I.. -ISpeaka -ISpeaka/Model -ISpeaka/UI -ISpeaka/UI/Transition
# Fake-signed with ldid. TrollStore keeps these entitlements when it installs the app.
Speaka_CODESIGN_FLAGS = -SSpeaka.entitlements

include $(THEOS_MAKE_PATH)/application.mk

# A .tipa is the staged, signed Speaka.app inside a Payload folder, zipped. The staged copy is used because
# Theos adds Resources/ (Info.plist, icons, license) to the bundle when it stages.
SPEAKA_STAGED_APP = $(THEOS_STAGING_DIR)/Applications/Speaka.app
SPEAKA_PAYLOAD = $(THEOS_OBJ_DIR)/tipa

tipa: stage
	@test -x "$(SPEAKA_STAGED_APP)/Speaka" || { echo "Speaka.app was not staged at $(SPEAKA_STAGED_APP)"; exit 1; }
	@rm -rf "$(SPEAKA_PAYLOAD)" && mkdir -p "$(SPEAKA_PAYLOAD)/Payload" "$(CURDIR)/packages"
	@cp -R "$(SPEAKA_STAGED_APP)" "$(SPEAKA_PAYLOAD)/Payload/"
	@rm -f "$(CURDIR)/packages/Speaka.tipa"
	@cd "$(SPEAKA_PAYLOAD)" && zip -qry "$(CURDIR)/packages/Speaka.tipa" Payload
	@echo "Built $(CURDIR)/packages/Speaka.tipa"

.PHONY: tipa
