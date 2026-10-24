// BTPSLogViewController.m
#import "BTPSLogViewController.h"
#import "BTPSLogReader.h"

@implementation BTPSLogViewController {
    UITextView *_textView;
    NSTimer *_timer;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Debug log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    _textView.textColor = [UIColor labelColor];
    _textView.backgroundColor = [UIColor systemBackgroundColor];
    _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_textView];

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

- (void)copyAll
{
    [UIPasteboard generalPasteboard].string = _textView.text;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"Copied the debug log."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
