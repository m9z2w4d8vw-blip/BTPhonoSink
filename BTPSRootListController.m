// BTPSRootListController.m
#import "BTPSRootListController.h"
#import "BTPSLogReader.h"
#import "BTPSLogViewController.h"

@implementation BTPSRootListController

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSpecifiers];           // refresh the status rows every time the page is shown
}

#pragma mark - values for the rows in Root.plist (the "get" selectors)

- (id)loadedValue:(id)specifier       { return [[BTPSLogReader shared] loadedSummary]; }
- (id)lastEventValue:(id)specifier    { return [[BTPSLogReader shared] lastEventSummary]; }
- (id)channelValue:(id)specifier      { return [[BTPSLogReader shared] channelSummary]; }

#pragma mark - buttons (the "action" selectors)

- (void)showLog:(id)specifier
{
    [self.navigationController pushViewController:[[BTPSLogViewController alloc] init] animated:YES];
}

- (void)copyLog:(id)specifier
{
    [UIPasteboard generalPasteboard].string = [[BTPSLogReader shared] fullText];
    [self say:@"Copied the debug log to the clipboard."];
}

- (void)clearLog:(id)specifier
{
    [self say:[[BTPSLogReader shared] clearAll]];
    [self reloadSpecifiers];
}

- (void)say:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
