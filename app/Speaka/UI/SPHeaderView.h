//
//  SPHeaderView.h
//  Speaka
//
//  Adapted from Dopamine's DOHeaderView.h.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPHeaderView : UIView

/// Speaka draws its title as text instead of Dopamine's logo image.
- (instancetype)initWithTitle:(NSString *)title subtitles:(NSArray<NSAttributedString *> *)subtitles;
- (void)setSubtitles:(NSArray<NSAttributedString *> *)subtitles;

@end

NS_ASSUME_NONNULL_END
