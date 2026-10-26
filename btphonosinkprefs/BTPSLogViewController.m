// BTPSLogViewController.m
// Debug log screen. Export uses the public Files picker from Preferences.app;
// it does not change the bluetoothd tweak, its sandbox or its runtime behavior.
#import "BTPSLogViewController.h"
#import "BTPSLogReader.h"

@interface BTPSLogViewController () <UIDocumentPickerDelegate>
@end

@implementation BTPSLogViewController {
    UITextView *_textView;
    NSTimer *_timer;
    NSURL *_pendingExportURL;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Debug log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    _textView.textColor = [UIColor labelColor];
    _textView.backgroundColor = [UIColor systemBackgroundColor];
    _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_textView];

    // Keep this action visible even while the user scrolls through a long trace.
    UIButton *exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    [exportButton setTitle:@"Save Log to iCloud Drive…" forState:UIControlStateNormal];
    [exportButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    exportButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    exportButton.backgroundColor = [UIColor systemBlueColor];
    exportButton.layer.cornerRadius = 11.0;
    [exportButton addTarget:self action:@selector(exportToFiles) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:exportButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:exportButton.topAnchor constant:-6.0],
        [exportButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [exportButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [exportButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12.0],
        [exportButton.heightAnchor constraintEqualToConstant:48.0]
    ]];

    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(copyAll)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self action:@selector(reload)];
    self.navigationItem.rightBarButtonItems = @[ copy, refresh ];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
    __weak __typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [weakSelf reload]; }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)reload
{
    // Keep following the newest line only if the reader was already at the bottom; otherwise leave the scroll alone.
    CGFloat bottom = _textView.contentOffset.y + _textView.bounds.size.height;
    BOOL atBottom = _textView.text.length == 0 || bottom >= _textView.contentSize.height - 40.0;
    CGPoint keep = _textView.contentOffset;

    _textView.text = [[BTPSLogReader shared] fullText];
    [_textView layoutIfNeeded];

    if (atBottom) {
        CGFloat y = _textView.contentSize.height - _textView.bounds.size.height + _textView.adjustedContentInset.bottom;
        if (y < -_textView.adjustedContentInset.top) y = -_textView.adjustedContentInset.top;
        [_textView setContentOffset:CGPointMake(0, y) animated:NO];
    } else {
        _textView.contentOffset = keep;
    }
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyAll
{
    [UIPasteboard generalPasteboard].string = _textView.text;
    [self showMessage:@"Copied the debug log." title:nil];
}

#pragma mark - Export current log to Files / iCloud Drive

- (void)cleanupPendingExport
{
    if (_pendingExportURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_pendingExportURL error:NULL];
        _pendingExportURL = nil;
    }
}

- (void)exportToFiles
{
    // Use a new, complete snapshot rather than only the visible / potentially stale text.
    NSString *log = [[BTPSLogReader shared] fullText];
    if (log.length == 0) {
        [self showMessage:@"There is no diagnostic log available to export." title:@"Nothing to save"];
        return;
    }

    // A timestamp and short UUID make exports distinguishable across restarts and repeated taps.
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *suffix = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *filename = [NSString stringWithFormat:@"BTPhonoSink-%@-%@.txt",
                          [fmt stringFromDate:[NSDate date]], suffix];
    NSURL *fileURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                      URLByAppendingPathComponent:filename];

    NSError *error = nil;
    if (![log writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showMessage:error.localizedDescription ?: @"Could not create the temporary log file."
                    title:@"Export failed"];
        return;
    }

    [self cleanupPendingExport];
    _pendingExportURL = fileURL;

    // iOS offers all enabled Files locations. The user chooses iCloud Drive and taps Save.
    // This does not require iCloud entitlements or write access from the bluetoothd process.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                                            initForExportingURLs:@[fileURL] asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The picker copied the file to the chosen provider; remove only our staging file.
    [self cleanupPendingExport];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    [self cleanupPendingExport];
}

@end
