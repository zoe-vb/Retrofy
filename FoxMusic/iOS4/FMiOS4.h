//
//  FMiOS4.h
//  Retrofy
//
//  Prefix header of the iOS 4.2.1 armv6 build (see FoxMusic/iOS4/build.sh). Fills in what the iOS 4.2 SDK
//  doesn't have, so the code shared with the iOS 6 app can stay as it is.
//

#ifdef __OBJC__

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// Weak references need iOS 5. The few there are hold on to view controllers briefly, strong is fine.
#undef __weak
#define __weak

// iOS 5 SDK.
#if __has_feature(objc_arc)
static inline id CFBridgingRelease(CFTypeRef object)
{
    return (__bridge_transfer id)object;
}
#endif

// A name for NULL since iOS 5.
#define DISPATCH_QUEUE_SERIAL NULL

// iOS 4.3. Retries the values that would make low numbers slightly more likely.
static inline u_int32_t FMiOS4RandomBelow(u_int32_t upperBound)
{
    if (upperBound < 2) return 0;
    u_int32_t minimum = (0xFFFFFFFFu - upperBound + 1) % upperBound;
    u_int32_t value;
    do {
        value = arc4random();
    } while (value < minimum);
    return value % upperBound;
}
#define arc4random_uniform FMiOS4RandomBelow

// iOS 6 names.
#define NSTextAlignment UITextAlignment
#define NSTextAlignmentLeft UITextAlignmentLeft
#define NSTextAlignmentCenter UITextAlignmentCenter
#define NSTextAlignmentRight UITextAlignmentRight
#define NSLineBreakByClipping UILineBreakModeClip

// A formal protocol since iOS 5.
@protocol NSURLConnectionDelegate <NSObject>
@end

// iOS 5 and 6 APIs, FMiOS4.m implements these.
@interface NSDictionary (FMiOS4)
- (id)objectForKeyedSubscript:(id)key;
@end

@interface NSMutableDictionary (FMiOS4)
- (void)setObject:(id)object forKeyedSubscript:(id)key;
@end

@interface NSArray (FMiOS4)
- (id)objectAtIndexedSubscript:(NSUInteger)index;
@end

@interface UIViewController (FMiOS4)
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)viewWillLayoutSubviews;
- (void)prepareForSegue:(id)segue sender:(id)sender;
@end

@interface UIImage (FMiOS4)
- (UIImage *)resizableImageWithCapInsets:(UIEdgeInsets)insets;
@end

@interface UITableView (FMiOS4)
// Storyboards registered the cells, here every call site gets a two line cell with a disclosure arrow.
- (UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath;
@end

// Declared so the shared code compiles, nothing creates one without storyboards.
@interface UIStoryboardSegue : NSObject
@property (readonly, nonatomic) NSString *identifier;
@end

// The lock screen shows no track info before iOS 5. Calls to this do nothing.
extern NSString *const MPNowPlayingInfoPropertyElapsedPlaybackTime;
extern NSString *const MPNowPlayingInfoPropertyPlaybackRate;

@interface MPNowPlayingInfoCenter : NSObject
@property (copy) NSDictionary *nowPlayingInfo;
+ (MPNowPlayingInfoCenter *)defaultCenter;
@end

// iOS 5. FMiOS4JSON.m has a parser with the same interface.
enum {
    NSJSONReadingAllowFragments = 1 << 2,
};
typedef NSUInteger NSJSONReadingOptions;

@interface NSJSONSerialization : NSObject
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error;
@end

#endif
