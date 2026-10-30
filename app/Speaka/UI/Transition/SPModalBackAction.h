//
//  SPModalBackAction.h
//  Speaka
//
//  Dopamine's DOModalBackAction.h, renamed: taps outside a card close it.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPModalBackAction : UIView

@property (nonatomic, copy, nullable) void (^action)(void);
@property (nonatomic) CGRect ignoreFrame;

- (instancetype)initWithAction:(void (^)(void))action;

@end

NS_ASSUME_NONNULL_END
