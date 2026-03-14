ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = WebKitWebContent

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WebKitHardening
WebKitHardening_FILES = Tweak.xm
WebKitHardening_USE_MODULES = 0
WebKitHardening_CFLAGS = -fobjc-arc
WebKitHardening_CXXFLAGS = -fobjc-arc -std=c++17
WebKitHardening_FRAMEWORKS = Foundation
WebKitHardening_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += WebKitHardeningPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
