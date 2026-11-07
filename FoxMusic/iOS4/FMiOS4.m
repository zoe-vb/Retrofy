//
//  FMiOS4.m
//  Retrofy
//
//  The iOS 5 and 6 APIs the shared code uses, for the iOS 4.2.1 build.
//

#import <MediaPlayer/MediaPlayer.h>

NSString *const MPNowPlayingInfoPropertyElapsedPlaybackTime = @"playbackDuration.elapsed";
NSString *const MPNowPlayingInfoPropertyPlaybackRate = @"playbackRate";

@implementation NSDictionary (FMiOS4)

- (id)objectForKeyedSubscript:(id)key
{
    return [self objectForKey:key];
}

@end

@implementation NSMutableDictionary (FMiOS4)

- (void)setObject:(id)object forKeyedSubscript:(id)key
{
    [self setObject:object forKey:key];
}

@end

@implementation NSArray (FMiOS4)

- (id)objectAtIndexedSubscript:(NSUInteger)index
{
    return [self objectAtIndex:index];
}

@end

@implementation UIViewController (FMiOS4)

- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion
{
    [self presentModalViewController:viewController animated:animated];
    if (completion) completion();
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion
{
    [self dismissModalViewControllerAnimated:animated];
    if (completion) completion();
}

- (void)viewWillLayoutSubviews
{
}

- (void)prepareForSegue:(id)segue sender:(id)sender
{
}

@end

@implementation UIImage (FMiOS4)

- (UIImage *)resizableImageWithCapInsets:(UIEdgeInsets)insets
{
    return [self stretchableImageWithLeftCapWidth:(NSInteger)insets.left topCapHeight:(NSInteger)insets.top];
}

@end

@implementation UITableView (FMiOS4)

- (UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [self dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

@end

@implementation MPNowPlayingInfoCenter

@synthesize nowPlayingInfo;

+ (MPNowPlayingInfoCenter *)defaultCenter
{
    static MPNowPlayingInfoCenter *defaultCenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultCenter = [[MPNowPlayingInfoCenter alloc] init];
    });
    return defaultCenter;
}

@end
