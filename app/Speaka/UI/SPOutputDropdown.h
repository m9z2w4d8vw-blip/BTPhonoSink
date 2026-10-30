//
//  SPOutputDropdown.h
//  Speaka
//
//  A Dopamine-style menu row ("Audio output" and the current choice) that unfolds into the list of outputs,
//  with Dopamine's spring animation, and folds back when one is picked.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPOutputDropdown : UIView

/// "speaker" | "headphones" | "any"
@property (nonatomic, copy) NSString *selectedMode;
@property (nonatomic, copy, nullable) void (^selectionHandler)(NSString *mode);
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
