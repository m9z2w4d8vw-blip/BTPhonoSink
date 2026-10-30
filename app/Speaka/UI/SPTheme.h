//
//  SPTheme.h
//  Speaka
//
//  The colours of Dopamine's default theme (see DOThemeManager / Themes.plist), with Speaka's own background,
//  drawn in code instead of a photo.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPTheme : NSObject

/// Panels and buttons: Dopamine's default actionMenuColor (#3F3F3F at 45%), scaled by alpha.
+ (UIColor *)menuColorWithAlpha:(CGFloat)alpha;
/// Cards: Dopamine's default windowColor (#4C4C4C at 60%), scaled by alpha.
+ (UIColor *)windowColorWithAlpha:(CGFloat)alpha;
/// Speaka's accent (the teal of the app icon).
+ (UIColor *)accentColor;
/// Speaka's background: soft glows of the icon's colours on deep indigo, sized for the screen.
+ (UIImage *)backgroundImageWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
