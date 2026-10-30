//
//  SPModalBackAction.m
//  Speaka
//
//  Dopamine's DOModalBackAction.m, renamed.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPModalBackAction.h"

@implementation SPModalBackAction

- (instancetype)initWithAction:(void (^)(void))action
{
    if (self = [super init]) {
        self.action = action;
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    if (CGRectContainsPoint(self.ignoreFrame, point))
        return NO;
    return [super pointInside:point withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (self.action)
        self.action();
}

@end
