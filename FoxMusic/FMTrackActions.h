//
//  FMTrackActions.h
//  FoxMusic
//
//  The + / ✓ button shown for a track on Now Playing and in track lists, like modern Spotify: + adds the
//  track to Liked Songs, ✓ offers removing it or adding it to a playlist.
//

#import <UIKit/UIKit.h>

#import "FMAppDelegate.h"

@interface FMTrackActions : NSObject <UIActionSheetDelegate, UIAlertViewDelegate>

+ (FMTrackActions *)sharedActions;

// A green ✓ when the track is in Liked Songs, a + otherwise.
+ (UIImage *)likeImageForSaved:(BOOL)saved size:(CGFloat)size;

// Puts the + / ✓ button in a track cell's accessory view, hidden until it's known whether the track is
// liked. Looks that up if needed.
+ (void)showLikeButtonInCell:(UITableViewCell *)cell forTrack:(FMSpotifyTrack *)track target:(id)target action:(SEL)action;
// The track list row a like button from showLikeButtonInCell: was tapped in.
+ (NSIndexPath *)indexPathForLikeButtonEvent:(UIEvent *)event inTableView:(UITableView *)tableView;

- (void)likeTappedForTrack:(FMSpotifyTrack *)track inViewController:(UIViewController *)viewController;

// A short message fading in and out near the bottom of the view controller's view.
- (void)showToast:(NSString *)message inViewController:(UIViewController *)viewController;

@end
