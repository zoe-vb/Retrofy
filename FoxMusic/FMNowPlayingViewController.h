//
//  FMNowPlayingViewController.h
//  FoxMusic
//
//  Spotify's iOS 6 Now Playing screen: the cover with a seek bar, shuffle and repeat across its top,
//  and the playback controls and volume below it. Built in code, so both storyboards share it.
//

#import <UIKit/UIKit.h>

@interface FMNowPlayingViewController : UIViewController

+ (NSString *)stringFromTime:(NSTimeInterval)time;

@end

@interface UIViewController (FMNowPlaying)

// Shows a Now Playing button on the right of the navigation bar while there's a track.
- (void)updateNowPlayingButton;
- (IBAction)showNowPlaying:(id)sender;

@end
