#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mman.h>
#import <unistd.h>
#import <notify.h>
#import <substrate.h>

static const char *const kExitNotify = "com.xiaoxuan654.webkitHardening/ExitWebContent";
static NSString *const kPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.xiaoxuan654.webkitHardening.plist";

struct WebKitHardeningSettings {
	bool enableHardening;
	bool disableJIT;
	bool disableWebAssembly;
	bool blockJITMemory;
};

static WebKitHardeningSettings gSettings;

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

static void LoadSettingsFromPrefsFile(void) {
	@autoreleasepool {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
		if (![prefs isKindOfClass:[NSDictionary class]]) prefs = nil;

		// Defaults are OFF when the file is missing.
		gSettings.enableHardening = ReadBoolFromObject(prefs[@"EnableHardening"], false);
		gSettings.disableJIT = ReadBoolFromObject(prefs[@"DisableJIT"], false);
		gSettings.disableWebAssembly = ReadBoolFromObject(prefs[@"DisableWebAssembly"], false);
		gSettings.blockJITMemory = ReadBoolFromObject(prefs[@"BlockJITMemory"], false);
	}
}

static inline bool ShouldDenyJITMappings(void) {
	return gSettings.enableHardening && (gSettings.blockJITMemory || gSettings.disableJIT);
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

		// Allow the prefs pane to request a clean restart without relying on killall permissions.
		int exitToken = 0;
		notify_register_dispatch(kExitNotify, &exitToken, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
			(void)t;
			_exit(0);
		});

		LoadSettingsFromPrefsFile();

		void *jscHandle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW);
		if (jscHandle) {
			// JSC::Options::useWebAssembly
			HookIfPresent(jscHandle, "__ZN3JSC7Options13useWebAssemblyEv", (void *)&repl_useWebAssembly, (void **)&orig_useWebAssembly);
		}

		// pthread_jit_write_protect_np (void on iOS) + mmap(MAP_JIT) as minimal executable-memory blockers.
		void *target = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
		if (target) {
			MSHookFunction(target, (void *)&repl_pthread_jit_write_protect_np, (void **)&orig_pthread_jit_write_protect_np);
		}

		void *mmapTarget = dlsym(RTLD_DEFAULT, "mmap");
		if (mmapTarget) {
			MSHookFunction(mmapTarget, (void *)&repl_mmap, (void **)&orig_mmap);
		}

		// No additional behavior here; settings apply after restarting WebKitWebContent.
	}
}
