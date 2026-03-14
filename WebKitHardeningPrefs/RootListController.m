#import "Preferences/PSListController.h"
#import "Preferences/PSSpecifier.h"
#import <dlfcn.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

__attribute__((constructor))
static void WebKitHardeningPrefsInit(void) {
	// Ensure Preferences classes are available at runtime even when we don't link Preferences.framework at build-time.
	dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);

	// When preferences change, proactively restart WebKitWebContent so changes apply immediately.
	static const char *const kPrefsReloadDarwinNotification = "com.xiaoxuan654.webkitHardening/ReloadPrefs";
	static int token = 0;
	notify_register_dispatch(kPrefsReloadDarwinNotification, &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
		(void)t;

		pid_t pid = 0;
		const char *argv[] = { "killall", "-9", "WebKitWebContent", NULL };
		posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
		if (pid > 0) {
			int status = 0;
			waitpid(pid, &status, 0);
		}
	});
}

@interface WebKitHardeningRootListController : PSListController
@end

@implementation WebKitHardeningRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

@end
