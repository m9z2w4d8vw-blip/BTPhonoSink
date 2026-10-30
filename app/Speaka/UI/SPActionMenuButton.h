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

+ (SPActionMenuButton *)buttonWithAction:(UIAction *)action chevron:(BOOL)chevron;

@end

NS_ASSUME_NONNULL_END
