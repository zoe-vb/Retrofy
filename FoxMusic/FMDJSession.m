//
//  FMDJSession.m
//  Retrofy
//
//  Spotify's AI DJ. A DJ session hands out picks about five at a time, with the DJ's commentary as text on the
//  tracks. They play as a list on Retrofy's Connect device, with more fetched before they run out. The DJ's voice
//  isn't part of the session, Spotify's apps speak the commentary with their own text to speech.
//

#import "FMDJSession.h"

#import "FMPlayer.h"
#import "FMSpotifyContent.h"

// Pages fetched up front, so playback doesn't stop after the first few picks.
static const NSUInteger FMDJStartPages = 3;
static const NSUInteger FMDJRefillPages = 2;

@interface FMDJSession ()
{
    FMSpotifyTrackArray *_queue;
    FMSpotifyTrackArray *_upcoming;
    NSString *_nextPageURL;
    BOOL _refilling;
    // Track ID to {intro, outro}.
    NSMutableDictionary *_commentary;
}
@property (readwrite) BOOL isActive;
@property (readwrite) BOOL isStarting;
@end

@implementation FMDJSession

+ (FMDJSession *)sharedSession
{
    static FMDJSession *sharedSession;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedSession = [[FMDJSession alloc] init];
    });
    return sharedSession;
}

- (id)init
{
    self = [super init];
    if (self) {
        _commentary = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackEvent:) name:FMLibrespotPlaybackEventNotification object:nil];
    }
    return self;
}

- (FMAppDelegate *)appDelegate
{
    return (FMAppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (void)start
{
    if (self.isStarting) return;
    if (![[self appDelegate] librespotHasLogin]) {
        [[[UIAlertView alloc] initWithTitle:@"Turn on playback" message:@"The DJ needs Spotify Connect: open Spotify on another phone or computer on the same Wi-Fi, tap the devices button and pick Retrofy." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil, nil] show];
        return;
    }

    self.isStarting = YES;
    _nextPageURL = nil;
    [_commentary removeAllObjects];
    _upcoming = nil;
    [self fetchPages:FMDJStartPages into:[FMSpotifyTrackArray trackArrayWithDictionary:nil] completion:^(FMSpotifyTrackArray *tracks, NSError *error) {
        self.isStarting = NO;
        if (!tracks.count) {
            [[self appDelegate] displayError:error ?: [NSError errorWithDomain:@"dj" code:1 userInfo:@{NSLocalizedFailureReasonErrorKey: @"DJ unavailable", NSLocalizedDescriptionKey: @"The DJ didn't pick anything."}]];
            return;
        }
        _queue = tracks;
        self.isActive = YES;
        [[FMPlayer sharedPlayer] playTracks:_queue startingAtIndex:0 contextName:@"DJ" contextURI:nil];
    }];
}

- (void)stop
{
    self.isActive = NO;
    _upcoming = nil;
}

- (BOOL)list:(FMSpotifyTrackArray *)list containsIdentifier:(NSString *)identifier
{
    for (NSUInteger index = 0; index < list.count; index++) {
        if ([[[list itemAtIndex:index] identifier] isEqualToString:identifier]) return YES;
    }
    return NO;
}

- (NSString *)commentaryForTrack:(FMSpotifyTrack *)track
{
    if (!self.isActive || !track.identifier) return nil;
    NSString *intro = [[_commentary objectForKey:track.identifier] objectForKey:@"intro"];
    if (intro) return intro;

    for (NSUInteger index = 1; index < _queue.count; index++) {
        if ([[[_queue itemAtIndex:index] identifier] isEqualToString:track.identifier]) {
            return [[_commentary objectForKey:[[_queue itemAtIndex:index - 1] identifier]] objectForKey:@"outro"];
        }
    }
    return nil;
}

- (void)playbackEvent:(NSNotification *)notification
{
    if (!self.isActive) return;
    int event = [notification.userInfo[@"event"] intValue];

    if (event == FMLibrespotPlaybackEventTrackChanged) {
        NSData *data = [notification.userInfo[@"uri"] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *track = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *identifier = [track isKindOfClass:[NSDictionary class]] ? [track objectForKey:@"id"] : nil;
        if (![identifier isKindOfClass:[NSString class]]) return;
        if (![self list:_queue containsIdentifier:identifier] && ![self list:_upcoming containsIdentifier:identifier]) {
            // Something else started playing.
            [self stop];
        } else if ([[[_queue itemAtIndex:_queue.count - 1] identifier] isEqualToString:identifier]) {
            [self refill];
        }
    } else if (event == FMLibrespotPlaybackEventEndOfTrack && _upcoming.count) {
        // The list ran out: carry on with the next picks.
        NSString *lastURI = [@"spotify:track:" stringByAppendingString:[[_queue itemAtIndex:_queue.count - 1] identifier]];
        if ([notification.userInfo[@"uri"] isEqualToString:lastURI]) {
            _queue = _upcoming;
            _upcoming = nil;
            [[FMPlayer sharedPlayer] playTracks:_queue startingAtIndex:0 contextName:@"DJ" contextURI:nil];
        }
    }
}

- (void)refill
{
    if (_refilling || _upcoming.count || !_nextPageURL) return;
    _refilling = YES;
    [self fetchPages:FMDJRefillPages into:[FMSpotifyTrackArray trackArrayWithDictionary:nil] completion:^(FMSpotifyTrackArray *tracks, NSError *error) {
        _refilling = NO;
        if (tracks.count) _upcoming = tracks;
        else NSLog(@"Couldn't get more DJ picks: %@", error.localizedDescription);
    }];
}

// Adds `count` pages of picks to `tracks`, stopping early if the session runs out.
- (void)fetchPages:(NSUInteger)count into:(FMSpotifyTrackArray *)tracks completion:(void(^)(FMSpotifyTrackArray *tracks, NSError *error))completion
{
    [FMSpotifyContent loadDJPage:_nextPageURL completion:^(NSDictionary *response, NSError *error) {
        NSArray *pages = [response objectForKey:@"pages"];
        NSDictionary *page = [pages isKindOfClass:[NSArray class]] && [pages count] ? [pages objectAtIndex:0] : nil;
        if (![page isKindOfClass:[NSDictionary class]]) {
            completion(tracks, error);
            return;
        }

        NSString *nextPageURL = [page objectForKey:@"next_page_url"];
        _nextPageURL = [nextPageURL isKindOfClass:[NSString class]] && [nextPageURL length] ? nextPageURL : nil;

        NSMutableArray *uris = [NSMutableArray array];
        NSArray *entries = [page objectForKey:@"tracks"];
        if ([entries isKindOfClass:[NSArray class]]) for (NSDictionary *entry in entries) {
            NSString *uri = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"uri"] : nil;
            if (![uri isKindOfClass:[NSString class]] || ![uri hasPrefix:@"spotify:track:"]) continue;
            [uris addObject:uri];
            [self rememberCommentary:[entry objectForKey:@"metadata"] forURI:uri];
        }

        void (^continueFetching)(void) = ^{
            if (count > 1 && _nextPageURL) [self fetchPages:count - 1 into:tracks completion:completion];
            else completion(tracks, nil);
        };
        if (!uris.count) {
            continueFetching();
            return;
        }
        [FMSpotifyContent loadTracks:uris completion:^(FMSpotifyTrackArray *pageTracks) {
            if (pageTracks) [tracks addItems:pageTracks];
            continueFetching();
        }];
    }];
}

- (void)rememberCommentary:(NSDictionary *)metadata forURI:(NSString *)uri
{
    if (![metadata isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *commentary = [NSMutableDictionary dictionary];
    NSString *intro = [self plainTextFromSSML:[metadata objectForKey:@"narration.intro.ssml"]];
    NSString *outro = [self plainTextFromSSML:[metadata objectForKey:@"narration.outro.ssml"]];
    if (intro) [commentary setObject:intro forKey:@"intro"];
    if (outro) [commentary setObject:outro forKey:@"outro"];
    if (commentary.count) [_commentary setObject:commentary forKey:[uri substringFromIndex:[@"spotify:track:" length]]];
}

// <speak>That's <entity ...>beabadoobee</entity>, doing it well.</speak> becomes That's beabadoobee, doing it well.
- (NSString *)plainTextFromSSML:(NSString *)ssml
{
    if (![ssml isKindOfClass:[NSString class]]) return nil;
    NSString *text = [ssml stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, ssml.length)];
    text = [text stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    text = [text stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
}

@end
