// BTPSRootListController.h - the BTPhonoSink page in Settings > Tweaks.
//
// PSListController lives in the private Preferences framework, which is not linked here (the CI build only has the
// public Xcode SDK). It is declared by hand instead and resolved at runtime from the Settings process, which has
// already loaded it. The bundle is linked with -undefined dynamic_lookup for exactly this reason.
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (void)reloadSpecifiers;
- (void)reloadSpecifierID:(NSString *)specifierID;   // refreshes one row by its "id" in Root.plist
@end

@interface BTPSRootListController : PSListController
@end
