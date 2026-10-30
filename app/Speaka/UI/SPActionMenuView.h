//
//  SPActionMenuView.h
//  Speaka
//
//  Adapted from Dopamine's DOActionMenuView.h: the same rounded, translucent panel. Speaka's rows are views
//  (the output menu and a button) instead of UIActions only.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPActionMenuView : UIView

@property (nonatomic, readonly) UIStackView *rowsView;

- (instancetype)initWithRows:(NSArray<UIView *> *)rows;

@end

NS_ASSUME_NONNULL_END
