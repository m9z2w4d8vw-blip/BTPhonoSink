//
//  SPMarqueeView.m
//  Speaka
//

#import "SPMarqueeView.h"
#include <math.h>
#import "SPTheme.h"

// Space between the end of the text and the next copy coming in behind it.
static const CGFloat SPMarqueeGap = 48;

@protocol SPMarqueeTicking <NSObject>
- (void)marqueeTick:(CADisplayLink *)link;
@end

// CADisplayLink retains its target. This proxy holds the view weakly, so the view can always be released.
@interface SPMarqueeProxy : NSObject
@property (nonatomic, weak) id<SPMarqueeTicking> target;
@end

@implementation SPMarqueeProxy
- (void)tick:(CADisplayLink *)link
{
    [self.target marqueeTick:link];
}
@end

@interface SPMarqueeView () <SPMarqueeTicking>
@property (nonatomic) UIImageView *iconView;
@property (nonatomic) UIView *clipView;
@property (nonatomic) UILabel *leadLabel;
@property (nonatomic) UILabel *trailLabel;
@property (nonatomic) CAGradientLayer *fadeMask;
@property (nonatomic, nullable) CADisplayLink *displayLink;
@property (nonatomic) CGFloat offset;
@property (nonatomic) CGFloat textWidth;
@property (nonatomic) CFTimeInterval lastTimestamp;
@end

@implementation SPMarqueeView

- (instancetype)init
{
    if (self = [super init]) {
        _pointsPerSecond = 32;
        _text = @"";
        _symbolName = @"dot.radiowaves.left.and.right";
        _symbolColor = [UIColor whiteColor];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [SPTheme menuColorWithAlpha:1.0];
        self.layer.cornerRadius = 14;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText | UIAccessibilityTraitUpdatesFrequently;

        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:self.iconView];

        self.clipView = [[UIView alloc] init];
        self.clipView.translatesAutoresizingMaskIntoConstraints = NO;
        self.clipView.clipsToBounds = YES;
        [self addSubview:self.clipView];

        self.leadLabel = [self makeLabel];
        self.trailLabel = [self makeLabel];
        [self.clipView addSubview:self.leadLabel];
        [self.clipView addSubview:self.trailLabel];

        // Soft edges, so the text slides in and out instead of being cut off.
        self.fadeMask = [CAGradientLayer layer];
        self.fadeMask.startPoint = CGPointMake(0, 0.5);
        self.fadeMask.endPoint = CGPointMake(1, 0.5);
        self.fadeMask.colors = @[ (id)[UIColor clearColor].CGColor, (id)[UIColor blackColor].CGColor,
                                  (id)[UIColor blackColor].CGColor, (id)[UIColor clearColor].CGColor ];
        self.fadeMask.locations = @[ @0.0, @0.08, @0.92, @1.0 ];
        self.clipView.layer.mask = self.fadeMask;

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:48],
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:22],
            [self.iconView.heightAnchor constraintEqualToConstant:22],
            [self.clipView.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
            [self.clipView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [self.clipView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.clipView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        [self applySymbol];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reduceMotionChanged)
                                                     name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    }
    return self;
}

- (UILabel *)makeLabel
{
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 1;
    return label;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_displayLink invalidate];
}

#pragma mark - Content

- (void)setText:(NSString *)text
{
    NSString *value = text ?: @"";
    if ([value isEqualToString:_text])
        return;
    _text = [value copy];
    self.leadLabel.text = _text;
    self.trailLabel.text = _text;
    self.textWidth = ceil([self.leadLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width);
    self.accessibilityLabel = _text;
    [self setNeedsLayout];
}

- (void)setSymbolName:(NSString *)symbolName
{
    if ([symbolName isEqualToString:_symbolName])
        return;
    _symbolName = [symbolName copy];
    [self applySymbol];
}

- (void)setSymbolColor:(UIColor *)symbolColor
{
    _symbolColor = symbolColor ?: [UIColor whiteColor];
    self.iconView.tintColor = _symbolColor;
}

- (void)applySymbol
{
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    self.iconView.image = [UIImage systemImageNamed:self.symbolName withConfiguration:configuration];
    self.iconView.tintColor = self.symbolColor;
}

#pragma mark - Layout

- (BOOL)scrolls
{
    return !UIAccessibilityIsReduceMotionEnabled();
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.fadeMask.frame = self.clipView.bounds;
    [CATransaction commit];
    [self layoutLabels];
}

// The text moves to the right. The lead copy slides out at the right edge while the trailing copy, one cycle
// behind it, comes in from the left; when the lead copy has moved a whole cycle the two swap roles seamlessly.
- (void)layoutLabels
{
    CGFloat width = self.clipView.bounds.size.width;
    CGFloat height = self.clipView.bounds.size.height;
    if (width <= 0)
        return;
    if (![self scrolls]) {
        self.trailLabel.hidden = YES;
        self.leadLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.leadLabel.frame = CGRectMake(0, 0, width, height);
        return;
    }
    self.trailLabel.hidden = NO;
    self.leadLabel.lineBreakMode = NSLineBreakByClipping;
    CGFloat cycle = MAX(self.textWidth + SPMarqueeGap, width);
    self.offset = fmod(self.offset, cycle);
    if (self.offset < 0)
        self.offset += cycle;
    self.leadLabel.frame = CGRectMake(self.offset, 0, self.textWidth, height);
    self.trailLabel.frame = CGRectMake(self.offset - cycle, 0, self.textWidth, height);
}

#pragma mark - Animation

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self updateDisplayLink];
}

- (void)reduceMotionChanged
{
    [self updateDisplayLink];
    [self setNeedsLayout];
}

// Only animate while on screen and while Reduce Motion is off.
- (void)updateDisplayLink
{
    BOOL run = self.window != nil && [self scrolls];
    if (run && !self.displayLink) {
        SPMarqueeProxy *proxy = [[SPMarqueeProxy alloc] init];
        proxy.target = self;
        self.displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        self.displayLink.preferredFramesPerSecond = 60;
        self.lastTimestamp = 0;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!run && self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

- (void)marqueeTick:(CADisplayLink *)link
{
    CFTimeInterval now = link.timestamp;
    if (self.lastTimestamp > 0) {
        CFTimeInterval delta = MIN(now - self.lastTimestamp, 0.1);   // no jump after a pause
        self.offset += self.pointsPerSecond * (CGFloat)delta;        // positive: rightward
        [self layoutLabels];
    }
    self.lastTimestamp = now;
}

@end
