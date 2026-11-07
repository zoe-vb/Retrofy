//
//  FMPlayer.h
//  FoxMusic
//
//  What the Now Playing screen shows and controls. Full tracks play on Retrofy's Spotify Connect device, so
//  Spotify runs the queue, and other devices can take over or cast to it. Without a Connect login, this keeps
//  its own queue of 30 second previews.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#import "FMAppDelegate.h"

// Posted on the main thread whenever the track, play state, shuffle or repeat changes.
extern NSString *const FMPlayerStateDidChangeNotification;

typedef enum {
    FMPlayerRepeatOff,
    FMPlayerRepeatAll,
    FMPlayerRepeatOne,
} FMPlayerRepeatMode;

@interface FMPlayer : NSObject <AVAudioPlayerDelegate>

+ (FMPlayer *)sharedPlayer;

// The list being played. Read live, so pages a playlist loads later are played too.
@property (readonly) FMSpotifyTrackArray *tracks;
@property (readonly) FMSpotifyTrack *currentTrack;
// Name of what's playing, e.g. the playlist, shown on the lock screen.
@property (readonly) NSString *contextName;
@property (readonly) UIImage *coverImage;

@property (readonly, nonatomic) BOOL isPlaying;
// YES while a track is starting.
@property (readonly) BOOL isLoading;
// YES when the track fell back to the 30 second preview.
@property (readonly) BOOL isPreview;

@property (readonly, nonatomic) NSTimeInterval position;
@property (readonly, nonatomic) NSTimeInterval duration;

@property (nonatomic) BOOL shuffle;
@property (nonatomic) FMPlayerRepeatMode repeatMode;

// contextURI is what Spotify plays from, like spotify:playlist:... nil plays just these tracks.
- (void)playTracks:(FMSpotifyTrackArray *)tracks startingAtIndex:(NSUInteger)index contextName:(NSString *)contextName contextURI:(NSString *)contextURI;

- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)next;
// Goes back to the start of the track, or to the previous track in the first few seconds.
- (void)previous;
- (void)seekToPosition:(NSTimeInterval)position;

@end
