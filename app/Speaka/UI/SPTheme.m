//
//  SPTheme.m
//  Speaka
//

#import "SPTheme.h"

static UIColor *SPColorFromARGB(uint32_t argb, CGFloat alphaScale)
{
    return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:((argb >> 24) & 0xFF) / 255.0 * alphaScale];
}

// One soft glow: the colour at the centre fading to transparent at the radius.
static void SPDrawGlow(CGContextRef context, CGColorSpaceRef space, CGPoint centre, CGFloat radius,
                       uint32_t rgb, CGFloat alpha)
{
    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0, g = ((rgb >> 8) & 0xFF) / 255.0, b = (rgb & 0xFF) / 255.0;
    CGFloat components[12] = { r, g, b, alpha,  r, g, b, alpha * 0.45,  r, g, b, 0.0 };
    CGFloat locations[3] = { 0.0, 0.45, 1.0 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
    CGContextDrawRadialGradient(context, gradient, centre, 0, centre, radius, 0);
    CGGradientRelease(gradient);
}

@implementation SPTheme

+ (UIColor *)menuColorWithAlpha:(CGFloat)alpha
{
    return SPColorFromARGB(0x723f3f3f, alpha);
}

+ (UIColor *)windowColorWithAlpha:(CGFloat)alpha
{
    return SPColorFromARGB(0x994c4c4c, alpha);
}

+ (UIColor *)accentColor
{
    return SPColorFromARGB(0xFF12B3A6, 1.0);
}

+ (UIImage *)backgroundImageWithSize:(CGSize)size
{
    if (size.width < 1 || size.height < 1)
        size = CGSizeMake(390, 844);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;   // smooth gradients need no retina detail
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGFloat w = size.width, h = size.height, m = MAX(w, h);
        [SPColorFromARGB(0xFF0D0A24, 1.0) setFill];
        CGContextFillRect(context, CGRectMake(0, 0, w, h));
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        SPDrawGlow(context, space, CGPointMake(w * 0.10, h * 0.12), m * 0.62, 0x5B2BB5, 0.95);   // violet
        SPDrawGlow(context, space, CGPointMake(w * 0.95, h * 0.30), m * 0.45, 0x2B4FD8, 0.60);   // blue
        SPDrawGlow(context, space, CGPointMake(w * 0.90, h * 0.92), m * 0.60, 0x12B3A6, 0.80);   // teal
        SPDrawGlow(context, space, CGPointMake(w * 0.05, h * 0.88), m * 0.42, 0xB0307A, 0.45);   // magenta
        CGColorSpaceRelease(space);
    }];
}

@end
