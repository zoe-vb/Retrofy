//
//  FMDJSession.h
//  Retrofy
//
//  Spotify's AI DJ. A DJ session hands out picks about five at a time, with the DJ's commentary as text on the
//  tracks. They play as a list on Retrofy's Connect device, with more fetched before they run out. The DJ's voice
//  isn't part of the session, Spotify's apps speak the commentary with their own text to speech.
//

#import <Foundation/Foundation.h>

#import "FMAppDelegate.h"

@interface FMDJSession : NSObject

+ (FMDJSession *)sharedSession;

@property (readonly) BOOL isActive;
@property (readonly) BOOL isStarting;

- (void)start;
- (void)stop;

// What the DJ says around this track, nil if nothing.
- (NSString *)commentaryForTrack:(FMSpotifyTrack *)track;

@end
