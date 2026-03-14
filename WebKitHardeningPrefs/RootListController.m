#import "Preferences/PSListController.h"
#import "Preferences/PSSpecifier.h"
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

static CFStringRef const kPrefsID = CFSTR("com.xiaoxuan654.webkitHardening");
static const char *const kExitNotify = "com.xiaoxuan654.webkitHardening/ExitWebContent";

__attribute__((constructor))
static void WebKitHardeningPrefsInit(void) {
	// Ensure Preferences classes are available at runtime even when we don't link Preferences.framework at build-time.
	dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
}

@interface WebKitHardeningRootListController : PSListController
@end

@implementation WebKitHardeningRootListController

- (void)updateEnabledStates {
	BOOL enabled = NO;
	CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("EnableHardening"), kPrefsID);
	if (value) {
		if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
			enabled = CFBooleanGetValue((CFBooleanRef)value);
		} else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
			int n = 0;
			if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n)) enabled = (n != 0);
		}
		CFRelease(value);
	}

	for (PSSpecifier *spec in _specifiers) {
		NSString *key = [spec propertyForKey:@"key"];
		if (![key isKindOfClass:[NSString class]]) continue;
		if ([key isEqualToString:@"DisableJIT"] ||
		    [key isEqualToString:@"DisableWebAssembly"] ||
		    [key isEqualToString:@"BlockJITMemory"]) {
			[spec setProperty:@(enabled) forKey:@"enabled"];
		}
	}
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self updateEnabledStates];
	}
	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:@"key"];
	id defaultValue = [specifier propertyForKey:@"default"];
	if (!key) return defaultValue;

	CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsID);
	if (!value) return defaultValue;
	return CFBridgingRelease(value);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:@"key"];
	if (!key) return;

	CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kPrefsID);
	CFPreferencesAppSynchronize(kPrefsID);

	// If the master switch changes, enable/disable dependent options.
	if ([key isEqualToString:@"EnableHardening"]) {
		[self updateEnabledStates];
		if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
			[(id)self performSelector:@selector(reloadSpecifiers)];
		}
	}
}

- (void)restartWebKitWebContent {
	notify_post(kExitNotify);

	const char *const envp[] = { "PATH=/var/jb/usr/bin:/usr/bin:/bin", NULL };
	const char *const candidates[] = { "/var/jb/usr/bin/killall", "/usr/bin/killall" };

	const char *killallPath = NULL;
	for (size_t i = 0; i < (sizeof(candidates) / sizeof(candidates[0])); i++) {
		if (access(candidates[i], X_OK) == 0) {
			killallPath = candidates[i];
			break;
		}
	}
	if (!killallPath) return;

	pid_t pid = 0;
	const char *argv[] = { "killall", "-9", "WebKitWebContent", NULL };
	int rc = posix_spawn(&pid, killallPath, NULL, NULL, (char *const *)argv, (char *const *)envp);
	if (rc != 0) return;
	if (pid > 0) {
		int status = 0;
		waitpid(pid, &status, 0);
	}
}

@end
