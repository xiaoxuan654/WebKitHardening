#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <substrate.h>
#import <sys/stat.h>
#import <stdarg.h>
#import <string.h>

static const char *const kExitNotify = "com.xiaoxuan654.webkitHardening/ExitWebContent";
static const char *const kPrefsChangedNotify = "com.xiaoxuan654.webkitHardening/PrefsChanged";

static NSString *const kPrefsPathRootless = @"/var/jb/var/mobile/Library/Preferences/com.xiaoxuan654.webkitHardening.plist";
static NSString *const kPrefsPathRootfulCompat = @"/var/mobile/Library/Preferences/com.xiaoxuan654.webkitHardening.plist";
static CFStringRef const kPrefsID = CFSTR("com.xiaoxuan654.webkitHardening");
static const char *const kLogPath = "/var/jb/tmp/WebKitHardening.log";

struct WebKitHardeningSettings {
	bool enableHardening;
	bool disableJIT;
	bool disableWebAssembly;
	bool blockJITMemory;
};

static WebKitHardeningSettings gSettings;

static int gLogFD = -1;

static void WKLog(NSString *fmt, ...) {
	@autoreleasepool {
		va_list ap;
		va_start(ap, fmt);
		NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
		va_end(ap);
		if (!msg) return;

		NSString *line = [NSString stringWithFormat:@"[WebKitHardening] %@\n", msg];
		const char *bytes = [line UTF8String];
		if (!bytes) return;

		// Always log to system log (useful if file write is denied).
		NSLog(@"%s", bytes);

		// Best-effort file log to /var/jb/tmp (requested).
		if (gLogFD >= 0) {
			(void)write(gLogFD, bytes, strlen(bytes));
		}
	}
}

static void WKOpenLogFile(void) {
	if (gLogFD >= 0) return;
	// Ensure /var/jb/tmp exists (it should on rootless, but be defensive).
	(void)mkdir("/var/jb/tmp", 0755);
	gLogFD = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static NSDictionary *LoadPrefsDictionary(void) {
	// PreferenceLoader/CFPreferences may write to /var/mobile/... even on rootless.
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPathRootfulCompat];
	if ([prefs isKindOfClass:[NSDictionary class]]) return prefs;
	prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPathRootless];
	if ([prefs isKindOfClass:[NSDictionary class]]) return prefs;
	return nil;
}

static bool ReadBoolFromObject(id obj, bool defaultValue) {
	if (!obj) return defaultValue;
	if ([obj isKindOfClass:[NSNumber class]]) return [obj boolValue];
	if ([obj isKindOfClass:[NSString class]]) {
		NSString *s = (NSString *)obj;
		if ([s isEqualToString:@"1"] || [s caseInsensitiveCompare:@"true"] == NSOrderedSame) return true;
		if ([s isEqualToString:@"0"] || [s caseInsensitiveCompare:@"false"] == NSOrderedSame) return false;
	}
	return defaultValue;
}

static bool ReadBoolFromCFPreferences(CFStringRef key, bool defaultValue) {
	CFPropertyListRef value = CFPreferencesCopyAppValue(key, kPrefsID);
	if (!value) return defaultValue;

	bool result = defaultValue;
	if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
		result = CFBooleanGetValue((CFBooleanRef)value);
	} else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
		int n = 0;
		if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n)) result = (n != 0);
	}
	CFRelease(value);
	return result;
}

static void LoadSettingsFromPrefsFile(void) {
	@autoreleasepool {
		NSDictionary *prefs = LoadPrefsDictionary();

		// Defaults are OFF when the file is missing.
		if (prefs) {
			gSettings.enableHardening = ReadBoolFromObject(prefs[@"EnableHardening"], false);
			gSettings.disableJIT = ReadBoolFromObject(prefs[@"DisableJIT"], false);
			gSettings.disableWebAssembly = ReadBoolFromObject(prefs[@"DisableWebAssembly"], false);
			gSettings.blockJITMemory = ReadBoolFromObject(prefs[@"BlockJITMemory"], false);
		} else {
			// Fallback: some environments do not allow file read, but CFPreferences still works.
			gSettings.enableHardening = ReadBoolFromCFPreferences(CFSTR("EnableHardening"), false);
			gSettings.disableJIT = ReadBoolFromCFPreferences(CFSTR("DisableJIT"), false);
			gSettings.disableWebAssembly = ReadBoolFromCFPreferences(CFSTR("DisableWebAssembly"), false);
			gSettings.blockJITMemory = ReadBoolFromCFPreferences(CFSTR("BlockJITMemory"), false);
		}
	}
}

static inline bool ShouldDenyJITMappings(void) {
	// If WebAssembly is "disabled" but option hooks fail due to symbol changes,
	// denying MAP_JIT provides a strong fallback that blocks common WASM compilation paths.
	return gSettings.enableHardening && (gSettings.blockJITMemory || gSettings.disableJIT || gSettings.disableWebAssembly);
}

static bool IsWebKitWebContentProcess(void) {
	@autoreleasepool {
		const char *prog = getprogname();
		if (prog && strcmp(prog, "WebKitWebContent") == 0) return true;

		NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
		return [bundleID isEqualToString:@"com.apple.WebKit.WebContent"];
	}
}

typedef bool (*JSCOptionBoolVoidFn)(void);

static JSCOptionBoolVoidFn orig_useWebAssembly = nullptr;
static JSCOptionBoolVoidFn orig_useWasmIPInt = nullptr;
static JSCOptionBoolVoidFn orig_useWasmBBQJIT = nullptr;
static JSCOptionBoolVoidFn orig_useWasmOMGJIT = nullptr;
static JSCOptionBoolVoidFn orig_useWasmSIMD = nullptr;

static JSCOptionBoolVoidFn orig_useJIT = nullptr;
static JSCOptionBoolVoidFn orig_useDFGJIT = nullptr;
static JSCOptionBoolVoidFn orig_useFTLJIT = nullptr;

static bool repl_useWebAssembly(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWebAssembly ? orig_useWebAssembly() : true;
}

static bool repl_useWasmIPInt(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWasmIPInt ? orig_useWasmIPInt() : true;
}

static bool repl_useWasmBBQJIT(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWasmBBQJIT ? orig_useWasmBBQJIT() : true;
}

static bool repl_useWasmOMGJIT(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWasmOMGJIT ? orig_useWasmOMGJIT() : true;
}

static bool repl_useWasmSIMD(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWasmSIMD ? orig_useWasmSIMD() : true;
}

static bool repl_useJIT(void) {
	if (gSettings.enableHardening && gSettings.disableJIT) return false;
	return orig_useJIT ? orig_useJIT() : true;
}

static bool repl_useDFGJIT(void) {
	if (gSettings.enableHardening && gSettings.disableJIT) return false;
	return orig_useDFGJIT ? orig_useDFGJIT() : true;
}

static bool repl_useFTLJIT(void) {
	if (gSettings.enableHardening && gSettings.disableJIT) return false;
	return orig_useFTLJIT ? orig_useFTLJIT() : true;
}

static void HookIfPresent(void *imageHandle, const char *symbol, void *replacement, void **originalOut) {
	if (!imageHandle || !symbol || !replacement || !originalOut) return;
	void *target = dlsym(imageHandle, symbol);
	if (!target) {
		WKLog(@"dlsym miss: %s", [NSString stringWithUTF8String:symbol].UTF8String);
		return;
	}
	WKLog(@"hook: %s -> %p", [NSString stringWithUTF8String:symbol].UTF8String, target);
	MSHookFunction(target, replacement, originalOut);
}

static void (*orig_pthread_jit_write_protect_np)(int enabled) = nullptr;

static void *(*orig_mmap)(void *addr, size_t len, int prot, int flags, int fd, off_t offset) = nullptr;

static void repl_pthread_jit_write_protect_np(int enabled) {
	if (ShouldDenyJITMappings()) {
		// Only block turning write-protection off; allowing "on" is safer.
		if (enabled == 0) {
			errno = EPERM;
			return;
		}
	}
	if (orig_pthread_jit_write_protect_np) orig_pthread_jit_write_protect_np(enabled);
}

static void *repl_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	if (ShouldDenyJITMappings()) {
		// Minimal-impact: deny only explicit JIT mappings.
		if ((flags & MAP_JIT) != 0) {
			errno = EPERM;
			return MAP_FAILED;
		}
	}
	return orig_mmap ? orig_mmap(addr, len, prot, flags, fd, offset) : MAP_FAILED;
}

%ctor {
	@autoreleasepool {
		if (!IsWebKitWebContentProcess()) return;

		WKOpenLogFile();

		// Allow the prefs pane to request a clean restart without relying on killall permissions.
		int exitToken = 0;
		notify_register_dispatch(kExitNotify, &exitToken, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
			(void)t;
			_exit(0);
		});

		LoadSettingsFromPrefsFile();
		WKLog(@"Loaded enable=%d jit=%d wasm=%d blockJITMem=%d",
		      gSettings.enableHardening, gSettings.disableJIT, gSettings.disableWebAssembly, gSettings.blockJITMemory);

		// Reload settings for debugging/verification (restart is still recommended).
		int prefsToken = 0;
		notify_register_dispatch(kPrefsChangedNotify, &prefsToken, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
			(void)t;
			LoadSettingsFromPrefsFile();
			WKLog(@"PrefsChanged enable=%d jit=%d wasm=%d blockJITMem=%d",
			      gSettings.enableHardening, gSettings.disableJIT, gSettings.disableWebAssembly, gSettings.blockJITMemory);
		});

		// If master is off, do not install hooks (matches your original requirement).
		if (!gSettings.enableHardening) return;

		void *jscHandle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW);
		if (jscHandle) {
			if (gSettings.disableWebAssembly) {
				WKLog(@"Installing WebAssembly option hooks");
				// JSC::Options::useWebAssembly and related WASM knobs (best-effort; symbols vary by iOS build).
				HookIfPresent(jscHandle, "__ZN3JSC7Options13useWebAssemblyEv", (void *)&repl_useWebAssembly, (void **)&orig_useWebAssembly);
				HookIfPresent(jscHandle, "__ZN3JSC7Options10useWasmIPIntEv", (void *)&repl_useWasmIPInt, (void **)&orig_useWasmIPInt);
				HookIfPresent(jscHandle, "__ZN3JSC7Options12useWasmBBQJITEv", (void *)&repl_useWasmBBQJIT, (void **)&orig_useWasmBBQJIT);
				HookIfPresent(jscHandle, "__ZN3JSC7Options12useWasmOMGJITEv", (void *)&repl_useWasmOMGJIT, (void **)&orig_useWasmOMGJIT);
				HookIfPresent(jscHandle, "__ZN3JSC7Options10useWasmSIMDEv", (void *)&repl_useWasmSIMD, (void **)&orig_useWasmSIMD);
			}

			if (gSettings.disableJIT) {
				WKLog(@"Installing JIT option hooks");
				// JSC::Options::useJIT/useDFGJIT/useFTLJIT
				HookIfPresent(jscHandle, "__ZN3JSC7Options6useJITEv", (void *)&repl_useJIT, (void **)&orig_useJIT);
				HookIfPresent(jscHandle, "__ZN3JSC7Options9useDFGJITEv", (void *)&repl_useDFGJIT, (void **)&orig_useDFGJIT);
				HookIfPresent(jscHandle, "__ZN3JSC7Options9useFTLJITEv", (void *)&repl_useFTLJIT, (void **)&orig_useFTLJIT);
			}
		}

		// pthread_jit_write_protect_np (void on iOS) + mmap(MAP_JIT) as minimal executable-memory blockers.
		if (ShouldDenyJITMappings()) {
			WKLog(@"Installing JIT executable-memory blockers (MAP_JIT / jit_write_protect)");
			void *target = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
			if (target) {
				MSHookFunction(target, (void *)&repl_pthread_jit_write_protect_np, (void **)&orig_pthread_jit_write_protect_np);
			}

			void *mmapTarget = dlsym(RTLD_DEFAULT, "mmap");
			if (mmapTarget) {
				MSHookFunction(mmapTarget, (void *)&repl_mmap, (void **)&orig_mmap);
			}
		}

		// No additional behavior here; settings apply after restarting WebKitWebContent.
	}
}
