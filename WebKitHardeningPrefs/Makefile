ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WebKitHardeningPrefs
WebKitHardeningPrefs_FILES = RootListController.m
WebKitHardeningPrefs_FRAMEWORKS = UIKit
WebKitHardeningPrefs_INSTALL_PATH = /Library/PreferenceBundles
WebKitHardeningPrefs_CFLAGS = -fobjc-arc -fno-modules
WebKitHardeningPrefs_RESOURCE_DIRS = Resources
WebKitHardeningPrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
