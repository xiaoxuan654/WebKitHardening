#import <UIKit/UIKit.h>

@class PSSpecifier;

// Minimal declarations to build preference bundles without linking the private Preferences.framework.
@interface PSListController : UIViewController {
@protected
	NSArray *_specifiers;
}

- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;

@end

