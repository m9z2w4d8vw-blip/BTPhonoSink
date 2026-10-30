//
//  SPBigButton.h
//  Speaka
//
//  Adapted from Dopamine's DOJailbreakButton.h: the same large rounded button. Speaka shows its "working" state
//  inside the button (Dopamine's title + double helix) instead of expanding into a log.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>
#import "SPActionMenuButton.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPBigButton : UIView

@property (nonatomic, readonly) SPActionMenuButton *button;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

- (instancetype)initWithAction:(UIAction *)action;
- (void)setTitle:(NSString *)title symbolName:(NSString *)symbolName;
- (void)setBusy:(BOOL)busy title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
