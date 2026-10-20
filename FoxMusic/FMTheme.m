//
//  FMTheme.m
//  FoxMusic
//
//  Dark Spotify look: charcoal bars and lists, white text, Spotify green accents.
//

#import "FMTheme.h"

@implementation FMTheme

+ (UIColor *)greenColor
{
    // Spotify's green from the iOS 6 era app.
    return [UIColor colorWithRed:132/255.0 green:189/255.0 blue:0 alpha:1];
}

+ (UIColor *)backgroundColor
{
    return [UIColor colorWithWhite:0.09 alpha:1];
}

+ (UIColor *)cellColor
{
    return [UIColor colorWithWhite:0.12 alpha:1];
}

+ (UIColor *)separatorColor
{
    return [UIColor colorWithWhite:0.2 alpha:1];
}

+ (UIColor *)textColor
{
    return [UIColor whiteColor];
}

+ (UIColor *)secondaryTextColor
{
    return [UIColor colorWithWhite:0.6 alpha:1];
}

// A 1 point wide vertical gradient with a highlight line on top and a dark line at the bottom, stretched across a bar.
+ (UIImage *)barImageWithHeight:(CGFloat)height top:(CGFloat)top bottom:(CGFloat)bottom topLine:(CGFloat)topLine bottomLine:(CGFloat)bottomLine
{
    CGSize size = CGSizeMake(1, height);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGFloat components[] = {top, 1, bottom, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(0, height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    [[UIColor colorWithWhite:topLine alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, 1, 1));
    [[UIColor colorWithWhite:bottomLine alpha:1] setFill];
    UIRectFill(CGRectMake(0, height - 1, 1, 1));

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0)];
}

+ (UIImage *)imageWithColor:(UIColor *)color
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0);
    [color setFill];
    UIRectFill(CGRectMake(0, 0, 1, 1));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (UIImage *)icon:(FMIcon)icon size:(CGFloat)size color:(UIColor *)color
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [color setFill];
    [color setStroke];
    CGFloat s = size;
    UIBezierPath *path = [UIBezierPath bezierPath];

    switch (icon) {
        case FMIconPlay:
            [path moveToPoint:CGPointMake(0.25 * s, 0.15 * s)];
            [path addLineToPoint:CGPointMake(0.85 * s, 0.5 * s)];
            [path addLineToPoint:CGPointMake(0.25 * s, 0.85 * s)];
            [path closePath];
            [path fill];
            break;
        case FMIconPause:
            [[UIBezierPath bezierPathWithRect:CGRectMake(0.24 * s, 0.17 * s, 0.18 * s, 0.66 * s)] fill];
            [[UIBezierPath bezierPathWithRect:CGRectMake(0.58 * s, 0.17 * s, 0.18 * s, 0.66 * s)] fill];
            break;
        case FMIconNext:
        case FMIconPrevious:
            [path moveToPoint:CGPointMake(0.12 * s, 0.22 * s)];
            [path addLineToPoint:CGPointMake(0.44 * s, 0.5 * s)];
            [path addLineToPoint:CGPointMake(0.12 * s, 0.78 * s)];
            [path closePath];
            [path moveToPoint:CGPointMake(0.44 * s, 0.22 * s)];
            [path addLineToPoint:CGPointMake(0.76 * s, 0.5 * s)];
            [path addLineToPoint:CGPointMake(0.44 * s, 0.78 * s)];
            [path closePath];
            [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(0.76 * s, 0.22 * s, 0.1 * s, 0.56 * s)]];
            if (icon == FMIconPrevious) {
                // Mirror it.
                [path applyTransform:CGAffineTransformMake(-1, 0, 0, 1, s, 0)];
            }
            [path fill];
            break;
        case FMIconShuffle: {
            path.lineWidth = 0.08 * s;
            [path moveToPoint:CGPointMake(0.08 * s, 0.3 * s)];
            [path addLineToPoint:CGPointMake(0.3 * s, 0.3 * s)];
            [path addLineToPoint:CGPointMake(0.58 * s, 0.7 * s)];
            [path addLineToPoint:CGPointMake(0.76 * s, 0.7 * s)];
            [path moveToPoint:CGPointMake(0.08 * s, 0.7 * s)];
            [path addLineToPoint:CGPointMake(0.3 * s, 0.7 * s)];
            [path addLineToPoint:CGPointMake(0.58 * s, 0.3 * s)];
            [path addLineToPoint:CGPointMake(0.76 * s, 0.3 * s)];
            [path stroke];
            for (NSNumber *y in @[@0.3, @0.7]) {
                UIBezierPath *arrow = [UIBezierPath bezierPath];
                [arrow moveToPoint:CGPointMake(0.74 * s, ([y doubleValue] - 0.13) * s)];
                [arrow addLineToPoint:CGPointMake(0.94 * s, [y doubleValue] * s)];
                [arrow addLineToPoint:CGPointMake(0.74 * s, ([y doubleValue] + 0.13) * s)];
                [arrow closePath];
                [arrow fill];
            }
            break;
        }
        case FMIconRepeat:
        case FMIconRepeatOne: {
            path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.12 * s, 0.3 * s, 0.76 * s, 0.42 * s) cornerRadius:0.14 * s];
            path.lineWidth = 0.08 * s;
            [path stroke];
            UIBezierPath *arrow = [UIBezierPath bezierPath];
            [arrow moveToPoint:CGPointMake(0.46 * s, 0.17 * s)];
            [arrow addLineToPoint:CGPointMake(0.66 * s, 0.3 * s)];
            [arrow addLineToPoint:CGPointMake(0.46 * s, 0.43 * s)];
            [arrow closePath];
            [arrow fill];
            if (icon == FMIconRepeatOne) {
                [@"1" drawInRect:CGRectMake(0, 0.36 * s, s, 0.32 * s) withFont:[UIFont boldSystemFontOfSize:0.26 * s] lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
            }
            break;
        }
        case FMIconSpeaker: {
            [path moveToPoint:CGPointMake(0.1 * s, 0.37 * s)];
            [path addLineToPoint:CGPointMake(0.28 * s, 0.37 * s)];
            [path addLineToPoint:CGPointMake(0.5 * s, 0.17 * s)];
            [path addLineToPoint:CGPointMake(0.5 * s, 0.83 * s)];
            [path addLineToPoint:CGPointMake(0.28 * s, 0.63 * s)];
            [path addLineToPoint:CGPointMake(0.1 * s, 0.63 * s)];
            [path closePath];
            [path fill];
            for (NSNumber *radius in @[@0.16, @0.3]) {
                UIBezierPath *wave = [UIBezierPath bezierPathWithArcCenter:CGPointMake(0.52 * s, 0.5 * s) radius:[radius doubleValue] * s startAngle:-M_PI_4 endAngle:M_PI_4 clockwise:YES];
                wave.lineWidth = 0.07 * s;
                [wave stroke];
            }
            break;
        }
        case FMIconAdd: {
            UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.12 * s, 0.12 * s, 0.76 * s, 0.76 * s)];
            circle.lineWidth = 0.06 * s;
            [circle stroke];
            UIRectFill(CGRectMake(0.47 * s, 0.3 * s, 0.06 * s, 0.4 * s));
            UIRectFill(CGRectMake(0.3 * s, 0.47 * s, 0.4 * s, 0.06 * s));
            break;
        }
        case FMIconAdded: {
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.09 * s, 0.09 * s, 0.82 * s, 0.82 * s)] fill];
            UIBezierPath *check = [UIBezierPath bezierPath];
            [check moveToPoint:CGPointMake(0.3 * s, 0.5 * s)];
            [check addLineToPoint:CGPointMake(0.44 * s, 0.64 * s)];
            [check addLineToPoint:CGPointMake(0.7 * s, 0.37 * s)];
            check.lineWidth = 0.08 * s;
            check.lineCapStyle = kCGLineCapRound;
            check.lineJoinStyle = kCGLineJoinRound;
            [[UIColor blackColor] setStroke];
            [check stroke];
            break;
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (UIImage *)thumbnailWithSize:(CGFloat)size drawing:(void(^)(CGRect rect))drawing
{
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:4] addClip];
    drawing(rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (UIImage *)thumbnailFromImage:(UIImage *)image size:(CGFloat)size
{
    return [self thumbnailWithSize:size drawing:^(CGRect rect){
        // Fill the square, cropping whatever sticks out.
        CGFloat scale = MAX(size / image.size.width, size / image.size.height);
        CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((size - drawSize.width) / 2, (size - drawSize.height) / 2, drawSize.width, drawSize.height)];
    }];
}

+ (UIImage *)playlistPlaceholderWithSize:(CGFloat)size
{
    return [self thumbnailWithSize:size drawing:^(CGRect rect){
        [[UIColor colorWithWhite:0.22 alpha:1] setFill];
        UIRectFill(rect);
        // A music note.
        [[self secondaryTextColor] setFill];
        CGFloat s = size;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.3 * s, 0.58 * s, 0.2 * s, 0.16 * s)] fill];
        UIRectFill(CGRectMake(0.46 * s, 0.26 * s, 0.05 * s, 0.42 * s));
        UIBezierPath *flag = [UIBezierPath bezierPath];
        [flag moveToPoint:CGPointMake(0.51 * s, 0.26 * s)];
        [flag addLineToPoint:CGPointMake(0.68 * s, 0.34 * s)];
        [flag addLineToPoint:CGPointMake(0.68 * s, 0.42 * s)];
        [flag addLineToPoint:CGPointMake(0.51 * s, 0.35 * s)];
        [flag closePath];
        [flag fill];
    }];
}

+ (UIImage *)likedSongsArtworkWithSize:(CGFloat)size
{
    return [self thumbnailWithSize:size drawing:^(CGRect rect){
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {0.27, 0.04, 0.96, 1, 0.77, 0.94, 0.85, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
        CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(size, size), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorSpace);

        CGFloat s = size;
        UIBezierPath *heart = [UIBezierPath bezierPath];
        [heart moveToPoint:CGPointMake(0.5 * s, 0.72 * s)];
        [heart addCurveToPoint:CGPointMake(0.5 * s, 0.38 * s) controlPoint1:CGPointMake(0.18 * s, 0.52 * s) controlPoint2:CGPointMake(0.3 * s, 0.22 * s)];
        [heart addCurveToPoint:CGPointMake(0.5 * s, 0.72 * s) controlPoint1:CGPointMake(0.7 * s, 0.22 * s) controlPoint2:CGPointMake(0.82 * s, 0.52 * s)];
        [heart closePath];
        [[UIColor whiteColor] setFill];
        [heart fill];
    }];
}

+ (void)applyAppearance
{
    UIColor *barButtonColor = [UIColor colorWithWhite:0.18 alpha:1];
    NSValue *shadowOffset = [NSValue valueWithUIOffset:UIOffsetMake(0, -1)];

    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    [[[UIApplication sharedApplication] delegate] window].backgroundColor = [self backgroundColor];

    UINavigationBar *navigationBar = [UINavigationBar appearance];
    [navigationBar setBackgroundImage:[self barImageWithHeight:44 top:0.2 bottom:0.11 topLine:0.3 bottomLine:0] forBarMetrics:UIBarMetricsDefault];
    [navigationBar setBackgroundImage:[self barImageWithHeight:32 top:0.2 bottom:0.11 topLine:0.3 bottomLine:0] forBarMetrics:UIBarMetricsLandscapePhone];
    [navigationBar setTintColor:barButtonColor];
    [navigationBar setTitleTextAttributes:@{UITextAttributeTextColor: [self textColor],
                                            UITextAttributeTextShadowColor: [UIColor blackColor],
                                            UITextAttributeTextShadowOffset: shadowOffset,
                                            UITextAttributeFont: [UIFont boldSystemFontOfSize:18]}];

    UIImage *toolbarImage = [self barImageWithHeight:44 top:0.13 bottom:0.05 topLine:0.22 bottomLine:0];
    UIToolbar *toolbar = [UIToolbar appearance];
    [toolbar setBackgroundImage:toolbarImage forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    [toolbar setBackgroundImage:toolbarImage forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsLandscapePhone];
    [toolbar setTintColor:barButtonColor];

    [[UIBarButtonItem appearance] setTintColor:barButtonColor];
    [[UIBarButtonItem appearance] setTitleTextAttributes:@{UITextAttributeTextColor: [self textColor],
                                                          UITextAttributeTextShadowColor: [UIColor blackColor],
                                                          UITextAttributeTextShadowOffset: shadowOffset} forState:UIControlStateNormal];

    UITabBar *tabBar = [UITabBar appearance];
    [tabBar setBackgroundImage:[self barImageWithHeight:49 top:0.11 bottom:0.03 topLine:0.22 bottomLine:0.03]];
    [tabBar setSelectionIndicatorImage:[self imageWithColor:[UIColor clearColor]]];
    [tabBar setSelectedImageTintColor:[self greenColor]];
    [[UITabBarItem appearance] setTitleTextAttributes:@{UITextAttributeTextColor: [self secondaryTextColor]} forState:UIControlStateNormal];
    [[UITabBarItem appearance] setTitleTextAttributes:@{UITextAttributeTextColor: [self greenColor]} forState:UIControlStateSelected];

    [[UISearchBar appearance] setTintColor:[UIColor colorWithWhite:0.15 alpha:1]];

    [[UIProgressView appearance] setProgressTintColor:[self greenColor]];
    [[UIProgressView appearance] setTrackTintColor:[self separatorColor]];
    [[UISlider appearance] setMinimumTrackTintColor:[self greenColor]];
    [[UISwitch appearance] setOnTintColor:[self greenColor]];
    [[UIPageControl appearance] setCurrentPageIndicatorTintColor:[self greenColor]];
}

+ (void)styleView:(UIView *)view
{
    view.backgroundColor = [self backgroundColor];
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            label.backgroundColor = [UIColor clearColor];
            label.textColor = label.font.pointSize > 20 ? [self textColor] : [self secondaryTextColor];
        } else if ([subview isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)subview;
            [button setTitleColor:[self greenColor] forState:UIControlStateNormal];
            [button setTitleColor:[self textColor] forState:UIControlStateHighlighted];
        } else if ([subview isMemberOfClass:[UIView class]]) {
            // Container views.
            subview.backgroundColor = [self backgroundColor];
        }
    }
}

+ (void)styleTableView:(UITableView *)tableView
{
    tableView.backgroundColor = [self backgroundColor];
    tableView.backgroundView = nil;
    tableView.separatorColor = [self separatorColor];
    tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    tableView.rowHeight = 56;
    // No empty separator lines below the last row.
    tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
}

+ (void)styleCell:(UITableViewCell *)cell
{
    cell.backgroundColor = [self cellColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [self textColor];
    cell.textLabel.highlightedTextColor = [self textColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = [self secondaryTextColor];
    cell.detailTextLabel.highlightedTextColor = [self textColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];

    if (![cell.selectedBackgroundView.backgroundColor isEqual:[self greenColor]]) {
        UIView *selectedBackgroundView = [[UIView alloc] initWithFrame:cell.bounds];
        selectedBackgroundView.backgroundColor = [self greenColor];
        cell.selectedBackgroundView = selectedBackgroundView;
    }
}

+ (UITableViewCell *)trackCellForTableView:(UITableView *)tableView
{
    static NSString *const identifier = @"FMTrackCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    return cell;
}

+ (void)styleCell:(UITableViewCell *)cell playing:(BOOL)playing
{
    if (playing) cell.textLabel.textColor = [self greenColor];
}

@end
