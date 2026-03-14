#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mman.h>
#import <notify.h>
#import <unistd.h>
#import <substrate.h>

static CFStringRef const kPrefsID = CFSTR("com.xiaoxuan654.webkitHardening");
static const char *const kPrefsReloadDarwinNotification = "com.xiaoxuan654.webkitHardening/ReloadPrefs";
static volatile bool gRestartScheduled = false;

static bool PrefBool(CFStringRef key, bool defaultValue) {
	CFPropertyListRef value = CFPreferencesCopyAppValue(key, kPrefsID);
	if (!value) return defaultValue;

	bool result = defaultValue;
	if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
		result = CFBooleanGetValue((CFBooleanRef)value);
	} else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
		int n = 0;
		if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n)) {
			result = (n != 0);
		}
	}
	CFRelease(value);
	return result;
}

struct WebKitHardeningSettings {
	bool enableHardening;
	bool disableJIT;
	bool disableWebAssembly;
	bool blockJITMemory;
};

static WebKitHardeningSettings gSettings;

static void LoadSettings(void) {
	gSettings.enableHardening = PrefBool(CFSTR("EnableHardening"), true);
	gSettings.disableJIT = PrefBool(CFSTR("DisableJIT"), true);
	gSettings.disableWebAssembly = PrefBool(CFSTR("DisableWebAssembly"), true);
	gSettings.blockJITMemory = PrefBool(CFSTR("BlockJITMemory"), true);
}

static void WriteStatusPrefs(void) {
	@autoreleasepool {
		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
		formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss 'UTC'";

		NSString *timestamp = [formatter stringFromDate:[NSDate date]] ?: @"Unknown";
		NSString *pidString = [NSString stringWithFormat:@"%d", getpid()];

		CFPreferencesSetAppValue(CFSTR("LastLoaded"), (__bridge CFStringRef)timestamp, kPrefsID);
		CFPreferencesSetAppValue(CFSTR("LastLoadedPID"), (__bridge CFStringRef)pidString, kPrefsID);
		CFPreferencesAppSynchronize(kPrefsID);
	}
}

static void ScheduleWebContentRestart(void) {
	// Coalesce repeated notifications into one restart.
	if (!__sync_bool_compare_and_swap(&gRestartScheduled, false, true)) return;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
	               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		// WebKitWebContent is managed by the system; exiting triggers a clean respawn on next use.
		_exit(0);
	});
}

static bool IsWebKitWebContentProcess(void) {
	@autoreleasepool {
		NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
		return [bundleID isEqualToString:@"com.apple.WebKit.WebContent"];
	}
}

typedef bool (*JSCOptionBoolVoidFn)(void);

static JSCOptionBoolVoidFn orig_useJIT = nullptr;
static JSCOptionBoolVoidFn orig_useDFGJIT = nullptr;
static JSCOptionBoolVoidFn orig_useFTLJIT = nullptr;
static JSCOptionBoolVoidFn orig_useWebAssembly = nullptr;

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

static bool repl_useWebAssembly(void) {
	if (gSettings.enableHardening && gSettings.disableWebAssembly) return false;
	return orig_useWebAssembly ? orig_useWebAssembly() : true;
}

static void HookIfPresent(void *imageHandle, const char *symbol, void *replacement, void **originalOut) {
	if (!imageHandle || !symbol || !replacement || !originalOut) return;
	void *target = dlsym(imageHandle, symbol);
	if (!target) return;
	MSHookFunction(target, replacement, originalOut);
}

static void (*orig_pthread_jit_write_protect_np)(int enabled) = nullptr;

static void *(*orig_mmap)(void *addr, size_t len, int prot, int flags, int fd, off_t offset) = nullptr;
static int (*orig_mprotect)(void *addr, size_t len, int prot) = nullptr;

static void repl_pthread_jit_write_protect_np(int enabled) {
	if (gSettings.enableHardening && gSettings.blockJITMemory) {
		// Only block turning write-protection off; allowing "on" is safer.
		if (enabled == 0) {
			errno = EPERM;
			return;
		}
	}
	if (orig_pthread_jit_write_protect_np) orig_pthread_jit_write_protect_np(enabled);
}

static void *repl_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	if (gSettings.enableHardening && gSettings.blockJITMemory) {
		// Best-effort: deny JIT mappings without relying on unstable internal JSC/bmalloc ABI.
		// MAP_JIT is the primary signal for JIT memory on iOS.
		if ((flags & MAP_JIT) != 0) {
			errno = EPERM;
			return MAP_FAILED;
		}
		// Also deny anonymous executable mappings.
		if (((flags & MAP_ANON) != 0) && ((prot & PROT_EXEC) != 0)) {
			errno = EPERM;
			return MAP_FAILED;
		}
	}
	return orig_mmap ? orig_mmap(addr, len, prot, flags, fd, offset) : MAP_FAILED;
}

static int repl_mprotect(void *addr, size_t len, int prot) {
	if (gSettings.enableHardening && gSettings.blockJITMemory) {
		if ((prot & PROT_EXEC) != 0) {
			errno = EPERM;
			return -1;
		}
	}
	return orig_mprotect ? orig_mprotect(addr, len, prot) : -1;
}

%ctor {
	@autoreleasepool {
		if (!IsWebKitWebContentProcess()) return;

		NSLog(@"[WebKitHardening] Loaded");

		LoadSettings();
		WriteStatusPrefs();

		// Live reload settings from PreferenceLoader without restarting WebContent.
		int token = 0;
		notify_register_dispatch(kPrefsReloadDarwinNotification, &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
			(void)t;
			LoadSettings();
			ScheduleWebContentRestart();
		});

		void *jscHandle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW);
		if (jscHandle) {
			// JSC::Options::useJIT / useDFGJIT / useFTLJIT
			HookIfPresent(jscHandle, "__ZN3JSC7Options6useJITEv", (void *)&repl_useJIT, (void **)&orig_useJIT);
			HookIfPresent(jscHandle, "__ZN3JSC7Options9useDFGJITEv", (void *)&repl_useDFGJIT, (void **)&orig_useDFGJIT);
			HookIfPresent(jscHandle, "__ZN3JSC7Options9useFTLJITEv", (void *)&repl_useFTLJIT, (void **)&orig_useFTLJIT);

			// JSC::Options::useWebAssembly
			HookIfPresent(jscHandle, "__ZN3JSC7Options13useWebAssemblyEv", (void *)&repl_useWebAssembly, (void **)&orig_useWebAssembly);
		}

		// pthread_jit_write_protect_np (void on iOS) + mmap/mprotect as stable executable-memory blockers.
		void *target = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
		if (target) {
			MSHookFunction(target, (void *)&repl_pthread_jit_write_protect_np, (void **)&orig_pthread_jit_write_protect_np);
		}

		void *mmapTarget = dlsym(RTLD_DEFAULT, "mmap");
		if (mmapTarget) {
			MSHookFunction(mmapTarget, (void *)&repl_mmap, (void **)&orig_mmap);
		}

		void *mprotectTarget = dlsym(RTLD_DEFAULT, "mprotect");
		if (mprotectTarget) {
			MSHookFunction(mprotectTarget, (void *)&repl_mprotect, (void **)&orig_mprotect);
		}

		if (gSettings.enableHardening && gSettings.disableJIT) {
			NSLog(@"[WebKitHardening] JIT disabled");
		}
	}
}
