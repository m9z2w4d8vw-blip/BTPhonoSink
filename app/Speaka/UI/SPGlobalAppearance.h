//
//  SPGlobalAppearance.h
//  Speaka
//
//  Adapted from Dopamine's DOGlobalAppearance.h (created by Lars Fröder on 10.10.23).
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define UI_IPAD_MAX_WIDTH 600
#define UI_MODAL_PADDING 30
#define UI_PADDING 30
// Action menu
#define UI_INNER_PADDING 20
#define UI_INNER_PADDING_TINY 10
#define UI_INNER_TOP_PADDING 5
#define UI_ACTION_HEIGHT 73
#define UI_ACTION_HEIGHT_HOME_BTN 65
#define UI_ACTION_HEIGHT_TINY 52

#define SE_PHONE_SIZE_CONST 568

@interface SPGlobalAppearance : NSObject

+ (UIImageSymbolConfiguration *)smallIconImageConfiguration;
+ (UIButtonConfiguration *)defaultButtonConfiguration;
+ (UIButtonConfiguration *)defaultButtonConfigurationWithImagePadding:(CGFloat)imagePadding;
+ (NSAttributedString *)mainSubtitleString:(NSString *)string;
+ (NSAttributedString *)secondarySubtitleString:(NSString *)string;
+ (BOOL)isHomeButtonDevice;
+ (BOOL)isRTL;
+ (BOOL)isSmallDevice;
/// The row height DOActionMenuView picks for the device (73, 65 with a home button, 52 on small phones).
+ (CGFloat)actionRowHeight;
/// The inner horizontal padding DOActionMenuView uses (20, or 10 on small phones).
+ (CGFloat)innerPadding;

@end

NS_ASSUME_NONNULL_END
