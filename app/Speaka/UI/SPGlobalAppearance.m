//
//  SPGlobalAppearance.m
//  Speaka
//
//  Adapted from Dopamine's DOGlobalAppearance.m (created by Lars Fröder on 10.10.23).
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPGlobalAppearance.h"
#import <CoreGraphics/CoreGraphics.h>

@implementation SPGlobalAppearance

+ (UIImageSymbolConfiguration *)smallIconImageConfiguration
{
    return [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
}

+ (UIButtonConfiguration *)defaultButtonConfiguration
{
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.imagePadding = 10;
    configuration.baseForegroundColor = [UIColor whiteColor];
    configuration.titleLineBreakMode = NSLineBreakByClipping;

    // From Dopamine: in dark mode UIKit highlights a configured button by adding white, which a white button cannot
    // show. A highlighted colour arrives in an RGB colour space and a normal one in a grey space, so dim the RGB
    // white to show the press.
    configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *textAttributes) {
        NSMutableDictionary<NSAttributedStringKey, id> *textAttributesM = textAttributes.mutableCopy;
        UIColor *foregroundColor = textAttributes[NSForegroundColorAttributeName];
        CGFloat alpha = 0, white = 0;
        [foregroundColor getWhite:&white alpha:&alpha];
        if ((int)white == 1 && (int)alpha == 1) {
            CGColorSpaceRef colorSpace = CGColorGetColorSpace(foregroundColor.CGColor);
            if (CGColorSpaceGetModel(colorSpace) == kCGColorSpaceModelRGB)
                textAttributesM[NSForegroundColorAttributeName] = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
        }
        return textAttributesM;
    };
    configuration.imageColorTransformer = ^UIColor *(UIColor *color) {
        CGFloat alpha = 0, white = 0;
        [color getWhite:&white alpha:&alpha];
        if ((int)white == 1 && (int)alpha == 1) {
            CGColorSpaceRef colorSpace = CGColorGetColorSpace(color.CGColor);
            if (CGColorSpaceGetModel(colorSpace) == kCGColorSpaceModelRGB)
                return [color colorWithAlphaComponent:0.75];
        }
        return color;
    };
    return configuration;
}

+ (UIButtonConfiguration *)defaultButtonConfigurationWithImagePadding:(CGFloat)imagePadding
{
    UIButtonConfiguration *configuration = [SPGlobalAppearance defaultButtonConfiguration];
    configuration.imagePadding = imagePadding;
    return configuration;
}

#pragma mark - Attributed Strings

+ (NSAttributedString *)mainSubtitleString:(NSString *)string
{
    return [[NSAttributedString alloc] initWithString:string attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    }];
}

+ (NSAttributedString *)secondarySubtitleString:(NSString *)string
{
    return [[NSAttributedString alloc] initWithString:string attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.60],
    }];
}

#pragma mark - Device

+ (BOOL)isHomeButtonDevice
{
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone &&
           [[UIApplication sharedApplication] keyWindow].safeAreaInsets.bottom == 0;
}

+ (BOOL)isRTL
{
    return [UIApplication sharedApplication].userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
}

+ (BOOL)isSmallDevice
{
    UIWindow *window = [[UIApplication sharedApplication] keyWindow];
    return window.frame.size.height < SE_PHONE_SIZE_CONST + 50;
}

+ (CGFloat)actionRowHeight
{
    if ([SPGlobalAppearance isSmallDevice])
        return UI_ACTION_HEIGHT_TINY;
    return [SPGlobalAppearance isHomeButtonDevice] ? UI_ACTION_HEIGHT_HOME_BTN : UI_ACTION_HEIGHT;
}

+ (CGFloat)innerPadding
{
    return [SPGlobalAppearance isSmallDevice] ? UI_INNER_PADDING_TINY : UI_INNER_PADDING;
}

@end
