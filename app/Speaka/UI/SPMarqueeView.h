//
//  SPMarqueeView.h
//  Speaka
//
//  The connection banner: an icon and a line of text that scrolls continuously to the RIGHT, in a Dopamine-style
//  translucent pill. With Reduce Motion on, the text stays still and is truncated instead.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPMarqueeView : UIView

@property (nonatomic, copy) NSString *text;
/// SF Symbol shown before the text.
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong) UIColor *symbolColor;
/// Scrolling speed, rightward. Default 32 points per second.
@property (nonatomic) CGFloat pointsPerSecond;

@end

NS_ASSUME_NONNULL_END
