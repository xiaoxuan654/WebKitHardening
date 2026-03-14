#import <Foundation/Foundation.h>

// Minimal declaration; PreferenceLoader/Preferences provides the real implementation at runtime.
@interface PSSpecifier : NSObject

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;

@end
