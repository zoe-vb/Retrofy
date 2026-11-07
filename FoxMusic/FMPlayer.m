//
//  FMPlayer.m
//  FoxMusic
//
//  What the Now Playing screen shows and controls. Full tracks play on Retrofy's Spotify Connect device, so
//  Spotify runs the queue, and other devices can take over or cast to it. Without a Connect login, this keeps
//  its own queue of 30 second previews.
//

#import "FMPlayer.h"

NSString *const FMPlayerStateDidChangeNotification = @"FMPlayerStateDidChangeNotification";

// Pressing previous later than this into a track restarts it instead.
static const NSTimeInterval FMPlayerRestartThreshold = 3;

// What was playing, saved so the next launch can show it paused where it was.
static NSString *const FMPlayerSavedQueueKey = @"FMPlayerSavedQueue";
static NSString *const FMPlayerSavedStateKey = @"FMPlayerSavedState";
// Tracks saved from the queue at most, around the current one.
static const NSUInteger FMPlayerMaximumSavedTracks = 500;

@interface FMPlayer ()
{
    NSUInteger _index;
    // Track indexes in play order while shuffling.
    NSMutableArray *_shuffleOrder;
    // Increased for every track started, so callbacks for an earlier track are ignored.
    NSUInteger _generation;
    // Tracks in a row that couldn't be played, so a queue of unplayable tracks doesn't loop forever.
    NSUInteger _failuresInARow;
    // The last librespot error shown, so a queue doesn't show the same alert for every track.
    NSString *_lastErrorMessage;
    // The full track couldn't start, which the rest of the queue would run into too.
    BOOL _fullTrackFailed;

    BOOL _usingLibrespot;
    BOOL _librespotPlaying;
    // librespot only reports the position when the state changes, the rest is counted from then.
    NSTimeInterval _librespotPosition;
    NSDate *_librespotPositionDate;

    // Where the current track starts when it's played, while it isn't loaded (after relaunching).
    NSTimeInterval _resumePosition;
    // What Spotify plays from, nil for a plain list of tracks.
    NSString *_contextURI;
}

@property (readwrite) FMSpotifyTrackArray *tracks;
@property (readwrite) FMSpotifyTrack *currentTrack;
@property (readwrite) NSString *contextName;
@property (readwrite) UIImage *coverImage;
@property (readwrite) BOOL isLoading;
@property (readwrite) BOOL isPreview;

@end

@implementation FMPlayer

+ (FMPlayer *)sharedPlayer
{
    static FMPlayer *sharedPlayer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedPlayer = [[FMPlayer alloc] init];
    });
    return sharedPlayer;
}

- (id)init
{
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(librespotPlaybackEvent:) name:FMLibrespotPlaybackEventNotification object:nil];
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification, UIApplicationWillTerminateNotification])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveQueue) name:name object:nil];
        [self restoreQueue];
    }
    return self;
}

- (FMAppDelegate *)appDelegate
{
    return (FMAppDelegate *)[[UIApplication sharedApplication] delegate];
}

// The preview player, if it's this queue's.
- (AVAudioPlayer *)previewPlayer
{
    AVAudioPlayer *audioPlayer = [[self appDelegate] audioPlayer];
    return audioPlayer.delegate == self ? audioPlayer : nil;
}

#pragma mark - State

- (BOOL)isPlaying
{
    if (_usingLibrespot) return _librespotPlaying;
    return [[self previewPlayer] isPlaying];
}

- (NSTimeInterval)position
{
    if (!_usingLibrespot) {
        AVAudioPlayer *previewPlayer = [self previewPlayer];
        return previewPlayer ? previewPlayer.currentTime : _resumePosition;
    }
    NSTimeInterval position = _librespotPosition;
    if (_librespotPlaying && _librespotPositionDate) position -= [_librespotPositionDate timeIntervalSinceNow];
    return [self clampedPosition:position];
}

- (NSTimeInterval)clampedPosition:(NSTimeInterval)position
{
    position = MAX(position, 0);
    return self.duration > 0 ? MIN(position, self.duration) : position;
}

- (NSTimeInterval)duration
{
    if (self.isPreview) return [[self previewPlayer] duration];
    return self.currentTrack.duration;
}

- (void)setLibrespotPosition:(NSTimeInterval)position playing:(BOOL)playing
{
    _librespotPosition = position;
    _librespotPositionDate = [NSDate date];
    _librespotPlaying = playing;
}

- (void)stateDidChange
{
    [self updateNowPlayingInfo];
    [self saveState];
    [[NSNotificationCenter defaultCenter] postNotificationName:FMPlayerStateDidChangeNotification object:self];
}

- (void)updateNowPlayingInfo
{
    FMSpotifyTrack *track = self.currentTrack;
    if (!track) {
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
        return;
    }
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
    [nowPlayingInfo setObject:track.name ?: @"Unknown Track" forKey:MPMediaItemPropertyTitle];
    NSString *albumTitle = track.album.name ?: self.contextName;
    if (albumTitle) [nowPlayingInfo setObject:albumTitle forKey:MPMediaItemPropertyAlbumTitle];
    if (track.artistName) [nowPlayingInfo setObject:track.artistName forKey:MPMediaItemPropertyArtist];
#ifndef FM_IOS4
    if (self.coverImage) [nowPlayingInfo setObject:[[MPMediaItemArtwork alloc] initWithImage:self.coverImage] forKey:MPMediaItemPropertyArtwork];
#endif
    if (self.duration > 0) [nowPlayingInfo setObject:@(self.duration) forKey:MPMediaItemPropertyPlaybackDuration];
    [nowPlayingInfo setObject:@(self.position) forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    [nowPlayingInfo setObject:@(self.isPlaying ? 1.0 : 0.0) forKey:MPNowPlayingInfoPropertyPlaybackRate];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
}

#pragma mark - Queue

- (void)playTracks:(FMSpotifyTrackArray *)tracks startingAtIndex:(NSUInteger)index contextName:(NSString *)contextName contextURI:(NSString *)contextURI
{
    if (index >= tracks.count) return;
    self.tracks = tracks;
    self.contextName = contextName;
    _contextURI = contextURI;
    _index = index;
    _failuresInARow = 0;
    _lastErrorMessage = nil;
    if (self.shuffle) [self reshuffle];
    [self startCurrentTrack];
    [self saveQueue];
}

// Play order position of the current track.
- (NSUInteger)orderPosition
{
    if (!self.shuffle) return _index;
    [self extendShuffleOrder];
    NSUInteger position = [_shuffleOrder indexOfObject:@(_index)];
    return position == NSNotFound ? 0 : position;
}

- (NSUInteger)trackIndexAtOrderPosition:(NSUInteger)position
{
    if (!self.shuffle) return position;
    [self extendShuffleOrder];
    return [[_shuffleOrder objectAtIndex:position] unsignedIntegerValue];
}

// The current track first, then everything else in random order.
- (void)reshuffle
{
    NSUInteger count = self.tracks.count;
    _shuffleOrder = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        if (index == _index) continue;
        [_shuffleOrder insertObject:@(index) atIndex:arc4random_uniform((u_int32_t)_shuffleOrder.count + 1)];
    }
    if (count) [_shuffleOrder insertObject:@(_index) atIndex:0];
}

// Playlists load page by page, shuffle the tracks that arrived since into the part not played yet.
- (void)extendShuffleOrder
{
    NSUInteger count = self.tracks.count;
    if (_shuffleOrder.count >= count) return;
    NSUInteger played = [_shuffleOrder indexOfObject:@(_index)];
    played = played == NSNotFound ? 0 : played + 1;
    for (NSUInteger index = _shuffleOrder.count; index < count; index++) {
        NSUInteger remaining = _shuffleOrder.count - played;
        [_shuffleOrder insertObject:@(index) atIndex:played + arc4random_uniform((u_int32_t)remaining + 1)];
    }
}

- (void)setShuffle:(BOOL)shuffle
{
    _shuffle = shuffle;
    if (_usingLibrespot) [[self appDelegate] librespotSetShuffle:shuffle];
    if (shuffle) [self reshuffle];
    else _shuffleOrder = nil;
    [self stateDidChange];
}

- (void)setRepeatMode:(FMPlayerRepeatMode)repeatMode
{
    _repeatMode = repeatMode;
    // FMPlayerRepeatMode has Connect's values.
    if (_usingLibrespot) [[self appDelegate] librespotSetRepeat:repeatMode];
    [self stateDidChange];
}

// Moves to the next track in play order. Returns NO at the end of the queue, which then stops on its first track.
- (BOOL)advance
{
    NSUInteger count = self.tracks.count;
    if (!count) return NO;
    NSUInteger position = [self orderPosition] + 1;
    if (position >= count) {
        _index = [self trackIndexAtOrderPosition:0];
        if (self.repeatMode != FMPlayerRepeatAll) return NO;
        return YES;
    }
    _index = [self trackIndexAtOrderPosition:position];
    return YES;
}

- (void)stopAtCurrentTrack
{
    _generation++;
    [self stopPlayback];
    _usingLibrespot = NO;
    _resumePosition = 0;
    self.isLoading = NO;
    self.isPreview = NO;
    self.currentTrack = [self.tracks itemAtIndex:_index];
    [self loadCoverForTrack:self.currentTrack];
    [self stateDidChange];
}

- (void)trackDidEnd
{
    if (self.repeatMode == FMPlayerRepeatOne) {
        [self startCurrentTrack];
        return;
    }
    if ([self advance]) [self startCurrentTrack];
    else [self stopAtCurrentTrack];
}

- (void)trackFailed
{
    if (++_failuresInARow >= MAX(self.tracks.count, 1)) {
        [self stopAtCurrentTrack];
        return;
    }
    if ([self advance]) [self startCurrentTrack];
    else [self stopAtCurrentTrack];
}

#pragma mark - Playback

- (void)stopPlayback
{
    AVAudioPlayer *previewPlayer = [self previewPlayer];
    if (previewPlayer) {
        [previewPlayer stop];
        previewPlayer.delegate = nil;
        [[self appDelegate] setAudioPlayer:nil];
    }
    if (_usingLibrespot) [[self appDelegate] librespotPause];
    _librespotPlaying = NO;
}

- (void)startCurrentTrack
{
    [self startCurrentTrackAtPosition:0];
}

- (void)startCurrentTrackAtPosition:(NSTimeInterval)startPosition
{
    FMSpotifyTrack *track = [self.tracks itemAtIndex:_index];
    if (!track) return;
    _resumePosition = 0;

    NSUInteger generation = ++_generation;
    [self stopPlayback];
    self.currentTrack = track;
    self.isLoading = YES;
    self.isPreview = NO;
    _usingLibrespot = NO;
    [self setLibrespotPosition:0 playing:NO];
    [[self appDelegate] setSelectedTrack:track];
    [self loadCoverForTrack:track];
    [self stateDidChange];

    if (![[self appDelegate] librespotAvailable]) {
        [self playPreviewOfTrack:track generation:generation startPosition:startPosition];
        return;
    }

    void (^completion)(NSError *) = ^(NSError *error){
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        // Connect's own events can get here first.
        if (generation != _generation) return;
        _fullTrackFailed = error != nil;
        if (error) {
            // Fall back to the 30 second preview.
            NSLog(@"librespot failed, playing the preview instead: %@", error.localizedDescription);
            if (![error.localizedDescription isEqualToString:_lastErrorMessage]) [[self appDelegate] displayError:error];
            _lastErrorMessage = error.localizedDescription;
            [self playPreviewOfTrack:track generation:generation startPosition:startPosition];
            return;
        }
        _usingLibrespot = YES;
        [self setLibrespotPosition:startPosition playing:NO];
        [self stateDidChange];
    };

    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    if (_contextURI) {
        NSString *startURI = track.identifier ? [@"spotify:track:" stringByAppendingString:track.identifier] : nil;
        [[self appDelegate] playContext:_contextURI tracks:nil startURI:startURI startIndex:0 shuffle:self.shuffle position:startPosition completion:completion];
        return;
    }
    NSMutableArray *trackURIs = [NSMutableArray array];
    NSUInteger startIndex = 0;
    for (NSUInteger index = 0; index < self.tracks.count; index++) {
        NSString *identifier = [[self.tracks itemAtIndex:index] identifier];
        if (!identifier) continue;
        if (index == _index) startIndex = trackURIs.count;
        [trackURIs addObject:[@"spotify:track:" stringByAppendingString:identifier]];
    }
    [[self appDelegate] playContext:nil tracks:trackURIs startURI:nil startIndex:startIndex shuffle:self.shuffle position:startPosition completion:completion];
}

- (void)playPreviewOfTrack:(FMSpotifyTrack *)track generation:(NSUInteger)generation startPosition:(NSTimeInterval)startPosition
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    [[[self appDelegate] spotifyClient] downloadTrack:track callback:^(NSData *musicData){
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != _generation) return;
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            self.isLoading = NO;

            NSError *error;
            AVAudioPlayer *audioPlayer = musicData.length ? [[AVAudioPlayer alloc] initWithData:musicData error:&error] : nil;
            if (!audioPlayer) {
                // Without Connect set up every track ends here. Stay on this one: that error was already
                // shown, and skipping through the queue with an alert per track helps nobody.
                if (_fullTrackFailed) {
                    [self stopAtCurrentTrack];
                    return;
                }
                [[self appDelegate] displayError:error ?: [NSError errorWithDomain:@"no_audio" code:1003 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Playback failed", NSLocalizedDescriptionKey: @"No audio could be loaded for this track."}]];
                [self trackFailed];
                return;
            }

            if ([[self appDelegate] librespotActive]) [[self appDelegate] librespotPause];
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback error:nil];
            [session setActive:YES error:nil];
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];

            audioPlayer.delegate = self;
            [[self appDelegate] setAudioPlayer:audioPlayer];
            [audioPlayer prepareToPlay];
            // The preview is only 30 seconds, a position further in starts it from the beginning.
            if (startPosition < audioPlayer.duration) audioPlayer.currentTime = startPosition;
            [audioPlayer play];
            _usingLibrespot = NO;
            _failuresInARow = 0;
            self.isPreview = YES;
            [self stateDidChange];
        });
    }];
}

- (void)loadCoverForTrack:(FMSpotifyTrack *)track
{
    self.coverImage = nil;
    NSURL *imageURL = track.album.imageURL;
    if (!imageURL) return;
    @try {
        [[[self appDelegate] spotifyClient] getDataFromURL:imageURL withCallback:^(NSData *data){
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!image || ![self.currentTrack isEqual:track]) return;
                self.coverImage = image;
                [self stateDidChange];
            });
        }];
    }
    @catch (NSException *exception) {
        NSLog(@"Error loading album cover: %@", exception.reason);
    }
}

- (void)play
{
    if (!self.currentTrack || self.isLoading || self.isPlaying) return;
    if (_usingLibrespot) {
        [[self appDelegate] librespotResume];
        [self setLibrespotPosition:_librespotPosition playing:YES];
    } else if ([self previewPlayer]) {
        [[self previewPlayer] play];
    } else {
        // Stopped at the end of the queue, or restored after relaunching.
        _failuresInARow = 0;
        [self startCurrentTrackAtPosition:_resumePosition];
        return;
    }
    [self stateDidChange];
}

- (void)pause
{
    if (!self.isPlaying) return;
    if (_usingLibrespot) {
        [self setLibrespotPosition:self.position playing:NO];
        [[self appDelegate] librespotPause];
    } else {
        [[self previewPlayer] pause];
    }
    [self stateDidChange];
}

- (void)togglePlayPause
{
    if (self.isPlaying) [self pause];
    else [self play];
}

- (void)next
{
    if (_usingLibrespot) {
        [[self appDelegate] librespotNext];
        return;
    }
    if (!self.tracks.count) return;
    _failuresInARow = 0;
    if ([self advance]) [self startCurrentTrack];
    else [self stopAtCurrentTrack];
}

- (void)previous
{
    if (_usingLibrespot) {
        [[self appDelegate] librespotPrevious];
        return;
    }
    if (!self.tracks.count) return;
    NSUInteger position = [self orderPosition];
    if (self.position > FMPlayerRestartThreshold || (position == 0 && self.repeatMode != FMPlayerRepeatAll)) {
        [self seekToPosition:0];
        return;
    }
    position = position == 0 ? self.tracks.count - 1 : position - 1;
    _index = [self trackIndexAtOrderPosition:position];
    _failuresInARow = 0;
    [self startCurrentTrack];
}

- (void)seekToPosition:(NSTimeInterval)position
{
    position = [self clampedPosition:position];
    if (_usingLibrespot) {
        [[self appDelegate] librespotSeekToPosition:position];
        [self setLibrespotPosition:position playing:_librespotPlaying];
    } else if ([self previewPlayer]) {
        [[self previewPlayer] setCurrentTime:position];
    } else {
        _resumePosition = position;
    }
    [self stateDidChange];
}

#pragma mark - Saving

// A track in the Web API's JSON shape, so FMSpotifyTrackArray can read it back.
- (NSDictionary *)dictionaryForTrack:(FMSpotifyTrack *)track
{
    NSMutableDictionary *album = [NSMutableDictionary dictionary];
    if (track.album.name) [album setObject:track.album.name forKey:@"name"];
    if (track.album.imageURL) [album setObject:@[@{@"url": [track.album.imageURL absoluteString]}] forKey:@"images"];
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithObject:album forKey:@"album"];
    if (track.identifier) [dictionary setObject:track.identifier forKey:@"id"];
    if (track.name) [dictionary setObject:track.name forKey:@"name"];
    NSMutableArray *artists = [NSMutableArray array];
    for (NSString *artistName in track.artistNames) [artists addObject:@{@"name": artistName}];
    [dictionary setObject:artists forKey:@"artists"];
    [dictionary setObject:@(round(track.duration * 1000)) forKey:@"duration_ms"];
    if (track.previewURL) [dictionary setObject:[track.previewURL absoluteString] forKey:@"preview_url"];
    return @{@"track": dictionary};
}

// The tracks, which only change when a new list is played or more of it loaded.
- (void)saveQueue
{
    NSUInteger count = self.tracks.count;
    if (!self.currentTrack || !count) return;
    NSUInteger first = _index > FMPlayerMaximumSavedTracks / 2 ? _index - FMPlayerMaximumSavedTracks / 2 : 0;
    NSUInteger last = MIN(count, first + FMPlayerMaximumSavedTracks);
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:last - first];
    for (NSUInteger index = first; index < last; index++) [items addObject:[self dictionaryForTrack:[self.tracks itemAtIndex:index]]];

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults setObject:@{@"items": items, @"first": @(first)} forKey:FMPlayerSavedQueueKey];
    [self saveState];
    [userDefaults synchronize];
}

// Where in the queue it is, saved on every change.
- (void)saveState
{
    if (!self.currentTrack) return;
    NSDictionary *queue = [[NSUserDefaults standardUserDefaults] objectForKey:FMPlayerSavedQueueKey];
    NSUInteger first = [[queue objectForKey:@"first"] unsignedIntegerValue];
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:@{@"index": @(_index >= first ? _index - first : 0),
                                                                                 @"position": @(self.position),
                                                                                 @"shuffle": @(self.shuffle),
                                                                                 @"repeat": @(self.repeatMode)}];
    if (self.contextName) [state setObject:self.contextName forKey:@"context"];
    if (_contextURI) [state setObject:_contextURI forKey:@"contextURI"];
    [[NSUserDefaults standardUserDefaults] setObject:state forKey:FMPlayerSavedStateKey];
}

// Shows the last track, paused where it was. Play starts it from there.
- (void)restoreQueue
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *queue = [userDefaults objectForKey:FMPlayerSavedQueueKey];
    NSDictionary *state = [userDefaults objectForKey:FMPlayerSavedStateKey];
    if (![queue isKindOfClass:[NSDictionary class]] || ![state isKindOfClass:[NSDictionary class]]) return;

    FMSpotifyTrackArray *tracks = [FMSpotifyTrackArray trackArrayWithDictionary:@{@"items": [queue objectForKey:@"items"] ?: @[]}];
    NSUInteger index = [[state objectForKey:@"index"] unsignedIntegerValue];
    if (index >= tracks.count) return;

    self.tracks = tracks;
    self.contextName = [state objectForKey:@"context"];
    _contextURI = [state objectForKey:@"contextURI"];
    _index = index;
    _shuffle = [[state objectForKey:@"shuffle"] boolValue];
    if (_shuffle) [self reshuffle];
    _repeatMode = [[state objectForKey:@"repeat"] intValue] % 3;
    self.currentTrack = [tracks itemAtIndex:index];
    _resumePosition = MAX([[state objectForKey:@"position"] doubleValue], 0);
    [self loadCoverForTrack:self.currentTrack];
    [self updateNowPlayingInfo];
}

#pragma mark - Events

// Takes in a track Spotify Connect started: the next one, or one another device cast here.
- (void)connectTrackChanged:(NSString *)json
{
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dictionary = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![dictionary isKindOfClass:[NSDictionary class]]) return;
    FMSpotifyTrack *track = [FMSpotifyTrack trackFromDictionary:dictionary];

    NSUInteger index = NSNotFound;
    for (NSUInteger candidate = 0; candidate < self.tracks.count; candidate++) {
        if ([[self.tracks itemAtIndex:candidate] isEqual:track]) {
            index = candidate;
            break;
        }
    }
    if (index == NSNotFound) {
        // Not from this list, keep it as the one track that gets saved and restored.
        self.tracks = [FMSpotifyTrackArray trackArrayWithDictionary:@{@"items": @[@{@"track": dictionary}]}];
        self.contextName = nil;
        _contextURI = nil;
        index = 0;
    }
    _index = index;
    self.currentTrack = track;
    [[self appDelegate] setSelectedTrack:track];
    [self loadCoverForTrack:track];
}

- (void)librespotPlaybackEvent:(NSNotification *)notification
{
    NSTimeInterval position = [notification.userInfo[@"position"] doubleValue] / 1000;
    int event = [notification.userInfo[@"event"] intValue];

    switch (event) {
        case FMLibrespotPlaybackEventTrackChanged:
            _generation++;
            _usingLibrespot = YES;
            _resumePosition = 0;
            self.isPreview = NO;
            [self setLibrespotPosition:0 playing:_librespotPlaying];
            [self connectTrackChanged:notification.userInfo[@"uri"]];
            break;
        case FMLibrespotPlaybackEventLoading:
            _usingLibrespot = YES;
            self.isLoading = YES;
            break;
        case FMLibrespotPlaybackEventPlaying:
            // Might have started on another device, which still needs the audio set up here.
            if (!_usingLibrespot || [self previewPlayer]) [[self appDelegate] prepareAudioSession];
            _usingLibrespot = YES;
            _failuresInARow = 0;
            _resumePosition = 0;
            self.isLoading = NO;
            self.isPreview = NO;
            [self setLibrespotPosition:position playing:YES];
            break;
        case FMLibrespotPlaybackEventPaused:
            self.isLoading = NO;
            [self setLibrespotPosition:position playing:NO];
            break;
        case FMLibrespotPlaybackEventPosition:
            [self setLibrespotPosition:position playing:_librespotPlaying];
            break;
        case FMLibrespotPlaybackEventStopped:
        case FMLibrespotPlaybackEventUnavailable:
            self.isLoading = NO;
            [self setLibrespotPosition:self.position playing:NO];
            break;
        case FMLibrespotPlaybackEventInactive:
            // Another device took over. Play picks up here again, from this position.
            if (!_usingLibrespot) return;
            _resumePosition = self.position;
            _usingLibrespot = NO;
            _librespotPlaying = NO;
            self.isLoading = NO;
            break;
        case FMLibrespotPlaybackEventShuffle:
            _shuffle = position > 0;
            break;
        case FMLibrespotPlaybackEventRepeat:
            _repeatMode = (FMPlayerRepeatMode)[notification.userInfo[@"position"] intValue];
            break;
        default:
            return;
    }
    [self stateDidChange];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag
{
    if (player == [self previewPlayer]) [self trackDidEnd];
}

@end
