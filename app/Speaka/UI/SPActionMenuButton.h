//
//  SPActionMenuButton.h
//  Speaka
//
//  Adapted from Dopamine's DOActionMenuButton.h.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPActionMenuButton : UIButton

@property (nonatomic) BOOL bottomSeparator;

/// Dopamine's constructor: the title and image come from the action, for rows whose text never changes.
+ (SPActionMenuButton *)buttonWithAction:(UIAction *)action chevron:(BOOL)chevron;

/// For buttons whose text changes later: the title and image live in the button's configuration and the action is
/// only the tap handler. (With a primary action, UIKit keeps re-applying the action's title over the configuration's,
/// which is why the Start button kept saying "Start" while the speaker was running.)
+ (SPActionMenuButton *)buttonWithTitle:(NSString *)title image:(nullable UIImage *)image action:(UIAction *)action chevron:(BOOL)chevron;

@end

NS_ASSUME_NONNULL_END
