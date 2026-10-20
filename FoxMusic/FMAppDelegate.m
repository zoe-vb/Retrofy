//
//  FMAppDelegate.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 26/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMAppDelegate.h"
#import "FMTheme.h"
#import "FMPlayer.h"

#ifdef FM_LIBRESPOT
#import "fmlibrespot.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

static void FMLibrespotEvent(void *context, int event, uint32_t positionMs, const char *detail);
static void FMWebAPILoginFinished(void *context, bool success, const char *detail);

// Port of the Web API login page, and the redirect URI registered for FMSpotifyClientID in Spotify's
// developer dashboard (override with FMSpotifyRedirectURI in the Info.plist).
static const uint16_t FMWebAPILoginPort = 8080;
static NSString *const FMDefaultRedirectURI = @"http://127.0.0.1:8888/callback";
#endif



@interface NSURLRequest (FoxesAreCool)
+ (BOOL)allowsAnyHTTPSCertificateForHost:(NSString *)host;
+ (void)setAllowsAnyHTTPSCertificate:(BOOL)allow forHost:(NSString *)host;
@end

NSString *const FMLibrespotDidLogInNotification = @"FMLibrespotDidLogInNotification";
NSString *const FMWebAPIDidLogInNotification = @"FMWebAPIDidLogInNotification";
NSString *const FMLibrespotPlaybackEventNotification = @"FMLibrespotPlaybackEventNotification";

@interface FMAppDelegate ()
- (void)librespotDidSendEvent:(int)event positionMs:(uint32_t)positionMs uri:(NSString *)uri;
@end

@implementation FMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [self setAlertDelegate:[[FMAlertDelegate alloc] init]];
    [FMTheme applyAppearance];
    // Brings back the last track, paused, from the previous launch.
    [FMPlayer sharedPlayer];
    // Override point for customization after application launch.
    [NSURLRequest setAllowsAnyHTTPSCertificate:YES forHost:@"*.spotify.com"];
    [NSURLRequest setAllowsAnyHTTPSCertificate:YES forHost:@"accounts.spotify.com"];

#ifdef FM_LIBRESPOT
    // Check that the Rust runtime works on this device.
    char *selfTest = fm_librespot_self_test();
    NSLog(@"librespot self test: %s", selfTest);
    fm_librespot_free_string(selfTest);
    _librespotQueue = dispatch_queue_create("Retrofy.librespot", DISPATCH_QUEUE_SERIAL);
    
    // Only the reusable login and the device ID live here, librespot never caches audio.
    NSString *libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *cacheDirectory = [libraryDirectory stringByAppendingPathComponent:@"librespot"];
    char *initError = NULL;
    if (!fm_librespot_init([cacheDirectory fileSystemRepresentation], (__bridge void *)self, FMLibrespotEvent, &initError)) {
        NSLog(@"librespot init failed: %s", initError);
        fm_librespot_free_string(initError);
    }
#endif

    return YES;
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message
{
    NSString *data = message;
    NSLog(@"hi %@", data);
}
							
- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    
    @try {
        // Ensure audio continues playing in the background
        if ([self audioPlayer] && [[self audioPlayer] isPlaying]) {
            // Audio will continue playing due to background modes in Info.plist
            NSLog(@"Audio continuing in background");
        }
    }
    @catch (NSException *exception) {
        NSLog(@"Exception entering background: %@", exception.reason);
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    
    @try {
        // Stop audio playback
        if (self.audioPlayer) {
            [self.audioPlayer stop];
            self.audioPlayer = nil;
        }
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:NO error:nil];
    }
    @catch (NSException *exception) {
        NSLog(@"Exception during app termination: %@", exception.reason);
    }
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSLog(@"%@, application: %@", url, sourceApplication);
    
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event
{
    @try {
        // The play queue handles the controls once something was played from a list.
        FMPlayer *player = [FMPlayer sharedPlayer];
        if (player.currentTrack) {
            switch (event.subtype) {
                case UIEventSubtypeRemoteControlPlay:
                    [player play];
                    break;
                case UIEventSubtypeRemoteControlPause:
                case UIEventSubtypeRemoteControlStop:
                    [player pause];
                    break;
                case UIEventSubtypeRemoteControlTogglePlayPause:
                    [player togglePlayPause];
                    break;
                case UIEventSubtypeRemoteControlNextTrack:
                    [player next];
                    break;
                case UIEventSubtypeRemoteControlPreviousTrack:
                    [player previous];
                    break;
                default:
                    break;
            }
            return;
        }

        if (self.librespotActive) {
            switch (event.subtype) {
                case UIEventSubtypeRemoteControlPlay:
                    [self librespotResume];
                    break;
                case UIEventSubtypeRemoteControlPause:
                case UIEventSubtypeRemoteControlStop:
                    [self librespotPause];
                    break;
                case UIEventSubtypeRemoteControlTogglePlayPause:
                    if (_librespotPlaying) [self librespotPause];
                    else [self librespotResume];
                    break;
                default:
                    break;
            }
            return;
        }

        AVAudioPlayer *audioPlayer = [self audioPlayer];
        if (!audioPlayer) {
            NSLog(@"No audio player available for remote control");
            return;
        }
        
        switch (event.subtype) {
            case UIEventSubtypeRemoteControlPlay:
                [[self audioPlayer] play];
                break;
                
            case UIEventSubtypeRemoteControlPause:
                [[self audioPlayer] pause];
                break;
                
            case UIEventSubtypeRemoteControlStop:
                [[self audioPlayer] stop];
                break;
                
            case UIEventSubtypeRemoteControlTogglePlayPause:
                if (audioPlayer.isPlaying)
                    [audioPlayer pause];
                else [audioPlayer play];
                break;
                
            default:
                break;
        }
    }
    @catch (NSException *exception) {
        NSLog(@"Exception in remote control: %@", exception.reason);
        [self displayException:exception];
    }
    
    [super remoteControlReceivedWithEvent:event];
}

- (void)displayError:(NSError *)error
{
    [self displayError:error withCompletionHandler:nil];
}

- (void)displayError:(NSError *)error withCompletionHandler:(void(^)())completionHandler
{
    bool debug = true;
    NSString *debugDescription = [[error userInfo] objectForKey:@"NSDebugDescription"];
    NSString *description = debugDescription ? [NSString stringWithFormat:@"%@\n%@", [error localizedDescription], debugDescription] : [error localizedDescription];
    
    NSString *debugButtonTitle = nil;
    
    if (debug) {
        debugButtonTitle = @"Details";
        
        [[self alertDelegate] setCompletionHandler:^void(int buttonIndex){
            if (buttonIndex == 1)
                [[[UIAlertView alloc] initWithTitle:[error localizedFailureReason] message:[error debugDescription] delegate:[self alertDelegate] cancelButtonTitle:@"Close" otherButtonTitles:nil, nil] show];
            if (completionHandler) completionHandler();
        }];
    } else [[self alertDelegate] setCompletionHandler:completionHandler];
    [[[UIAlertView alloc] initWithTitle:[error localizedFailureReason] message:description delegate:[self alertDelegate] cancelButtonTitle:@"Close" otherButtonTitles:debugButtonTitle, nil] show];
}

- (void)displayException:(NSException *)exception
{
    [[[UIAlertView alloc] initWithTitle:@"Whoops!" message:exception.description delegate:[self alertDelegate] cancelButtonTitle:@"Sorry" otherButtonTitles:nil, nil] show];
}

- (void)loadAudioFromData:(NSData *)audioData
{
    @try {
        if (!audioData || audioData.length == 0) {
            NSLog(@"No audio data provided");
            return;
        }
        
        NSError *error;
        AVAudioPlayer *audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&error];
        
        if (error) {
            NSLog(@"Error creating audio player: %@", error.localizedDescription);
            [self displayError:error];
            return;
        }
        
        [self setAudioPlayer:audioPlayer];
        [audioPlayer prepareToPlay];
    }
    @catch (NSException *exception) {
        NSLog(@"Exception loading audio: %@", exception.reason);
        [self displayException:exception];
    }
}

- (void)play
{
    @try {
        AVAudioPlayer *audioPlayer = [self audioPlayer];
        if (!audioPlayer) {
            NSLog(@"No audio player available");
            return;
        }
        
        [audioPlayer prepareToPlay];
        BOOL success = [audioPlayer play];
        if (!success)
            NSLog(@"Failed to start audio playback");
    }
    @catch (NSException *exception) {
        NSLog(@"Exception playing audio: %@", exception.reason);
        [self displayException:exception];
    }
}

#pragma mark - librespot

#ifdef FM_LIBRESPOT
// Called on a librespot thread.
static void FMLibrespotEvent(void *context, int event, uint32_t positionMs, const char *detail)
{
    FMAppDelegate *appDelegate = (__bridge FMAppDelegate *)context;
    NSString *detailString = detail ? [NSString stringWithUTF8String:detail] : @"";
    if (event == FM_LIBRESPOT_EVENT_LOG) {
        // Straight from the calling thread, so the order of messages is kept.
        NSLog(@"librespot: %@", detailString);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [appDelegate librespotDidSendEvent:event positionMs:positionMs uri:detailString];
    });
}
#endif

- (void)librespotDidSendEvent:(int)event positionMs:(uint32_t)positionMs uri:(NSString *)uri
{
#ifdef FM_LIBRESPOT
    NSLog(@"librespot event %d at %u ms: %@", event, positionMs, uri);
    if (event >= FMLibrespotPlaybackEventPlaying && event <= FMLibrespotPlaybackEventUnavailable)
        [[NSNotificationCenter defaultCenter] postNotificationName:FMLibrespotPlaybackEventNotification object:self userInfo:@{@"event": @(event), @"position": @(positionMs), @"uri": uri ?: @""}];
    switch (event) {
        case FM_LIBRESPOT_EVENT_PLAYING:
            _librespotPlaying = YES;
            break;
        case FM_LIBRESPOT_EVENT_PAUSED:
        case FM_LIBRESPOT_EVENT_STOPPED:
        case FM_LIBRESPOT_EVENT_END_OF_TRACK:
            _librespotPlaying = NO;
            break;
        case FM_LIBRESPOT_EVENT_LOGGED_IN:
            // One login is enough, stop showing up in other devices' Spotify device lists.
            [self stopLibrespotDiscovery];
            [[NSNotificationCenter defaultCenter] postNotificationName:FMLibrespotDidLogInNotification object:self userInfo:@{@"username": uri}];
            break;
        case FM_LIBRESPOT_EVENT_LOGIN_FAILED:
            [self displayError:[NSError errorWithDomain:@"librespot" code:8 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Spotify Connect login failed", NSLocalizedDescriptionKey: uri}]];
            break;
        case FM_LIBRESPOT_EVENT_UNAVAILABLE:
            _librespotPlaying = NO;
            [self displayError:[NSError errorWithDomain:@"librespot" code:5 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Track unavailable", NSLocalizedDescriptionKey: @"Spotify couldn't play this track. It may not be available in your country."}]];
            break;
        default:
            break;
    }
#endif
}

- (BOOL)librespotAvailable
{
#ifdef FM_LIBRESPOT
    return YES;
#else
    return NO;
#endif
}

- (void)playTrackWithLibrespot:(FMSpotifyTrack *)track completion:(void (^)(NSError *))completion
{
    [self playTrackWithLibrespot:track position:0 completion:completion];
}

- (void)playTrackWithLibrespot:(FMSpotifyTrack *)track position:(NSTimeInterval)position completion:(void (^)(NSError *))completion
{
#ifdef FM_LIBRESPOT
    if (!track.identifier) {
        if (completion) completion([NSError errorWithDomain:@"librespot" code:1 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Can't play track", NSLocalizedDescriptionKey: @"This track has no Spotify ID, local files can't be streamed."}]);
        return;
    }

    // The previous player has to stop, only one of them can use the audio session.
    [self.audioPlayer stop];
    self.audioPlayer = nil;

    NSError *sessionError;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayback error:&sessionError];
    [audioSession setActive:YES error:&sessionError];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];

    NSString *uri = [@"spotify:track:" stringByAppendingString:track.identifier];

    dispatch_async(_librespotQueue, ^{
        // Logs back in with the saved Spotify Connect login first if needed, which blocks.
        NSError *error;
        char *loadError = NULL;
        if (!fm_librespot_has_login()) {
            // Playback needs the Spotify Connect login, announce Retrofy so it can be picked right away.
            fm_librespot_start_discovery("Retrofy", NULL);
            error = [NSError errorWithDomain:@"librespot" code:2 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Playback not set up", NSLocalizedDescriptionKey: @"Open Spotify on another phone or computer on the same Wi-Fi, tap the devices button and pick Retrofy, then press Play again."}];
        } else if (!fm_librespot_load([uri UTF8String], true, (uint32_t)MAX(position * 1000, 0), &loadError)) {
            NSString *message = loadError ? [NSString stringWithUTF8String:loadError] : @"Unknown error";
            fm_librespot_free_string(loadError);
            error = [NSError errorWithDomain:@"librespot" code:3 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Can't play track", NSLocalizedDescriptionKey: message}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            _librespotActive = !error;
            if (completion) completion(error);
        });
    });
#else
    if (completion) completion([NSError errorWithDomain:@"librespot" code:0 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Not available", NSLocalizedDescriptionKey: @"This build doesn't include librespot."}]);
#endif
}

- (BOOL)startLibrespotDiscoveryWithError:(NSError **)error
{
#ifdef FM_LIBRESPOT
    char *discoveryError = NULL;
    if (fm_librespot_start_discovery("Retrofy", &discoveryError)) return YES;
    NSString *message = discoveryError ? [NSString stringWithUTF8String:discoveryError] : @"Unknown error";
    fm_librespot_free_string(discoveryError);
    if (error) *error = [NSError errorWithDomain:@"librespot" code:9 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Spotify Connect unavailable", NSLocalizedDescriptionKey: message}];
#endif
    return NO;
}

- (void)stopLibrespotDiscovery
{
#ifdef FM_LIBRESPOT
    fm_librespot_stop_discovery();
#endif
}

- (BOOL)librespotHasLogin
{
#ifdef FM_LIBRESPOT
    return fm_librespot_has_login();
#else
    return NO;
#endif
}

#ifdef FM_LIBRESPOT
// Called on the login page's thread with the token response JSON, or an error message.
static void FMWebAPILoginFinished(void *context, bool success, const char *detail)
{
    FMAppDelegate *appDelegate = (__bridge FMAppDelegate *)context;
    NSData *data = detail ? [NSData dataWithBytes:detail length:strlen(detail)] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *tokenResponse = success && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![tokenResponse isKindOfClass:[NSDictionary class]]) {
            [appDelegate displayError:[NSError errorWithDomain:@"webapi_login" code:1 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Web API login failed", NSLocalizedDescriptionKey: data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"No response"}]];
            return;
        }
        [appDelegate.spotifyClient setTokenFromDictionary:tokenResponse];
        NSLog(@"Web API login finished: %@", appDelegate.spotifyClient.token);
        [[NSNotificationCenter defaultCenter] postNotificationName:FMWebAPIDidLogInNotification object:appDelegate];
    });
}

// The iPhone's Wi-Fi IPv4 address, which is where the login page can be reached.
static NSString *FMWiFiAddress(void)
{
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
            if (!interface->ifa_addr || interface->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(interface->ifa_name, "en0") != 0) continue;
            char buffer[INET_ADDRSTRLEN];
            const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)interface->ifa_addr;
            if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer))) address = [NSString stringWithUTF8String:buffer];
        }
        freeifaddrs(interfaces);
    }
    return address;
}
#endif

- (NSString *)startWebAPILoginWithError:(NSError **)error
{
#ifdef FM_LIBRESPOT
    NSString *address = FMWiFiAddress();
    if (!address) {
        if (error) *error = [NSError errorWithDomain:@"webapi_login" code:2 userInfo:@{NSLocalizedFailureReasonErrorKey: @"No Wi-Fi", NSLocalizedDescriptionKey: @"Connect the iPhone to Wi-Fi to log in."}];
        return nil;
    }
    NSString *redirectURI = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"FMSpotifyRedirectURI"];
    if (![redirectURI isKindOfClass:[NSString class]] || ![redirectURI length]) redirectURI = FMDefaultRedirectURI;

    char *loginError = NULL;
    if (!fm_webapi_login_start([self.spotifyClient.clientId UTF8String], [redirectURI UTF8String], FMWebAPILoginPort, (__bridge void *)self, FMWebAPILoginFinished, &loginError)) {
        NSString *message = loginError ? [NSString stringWithUTF8String:loginError] : @"Unknown error";
        fm_librespot_free_string(loginError);
        if (error) *error = [NSError errorWithDomain:@"webapi_login" code:3 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Couldn't start the login page", NSLocalizedDescriptionKey: message}];
        return nil;
    }
    return [NSString stringWithFormat:@"http://%@:%u", address, FMWebAPILoginPort];
#else
    return nil;
#endif
}

- (void)stopWebAPILogin
{
#ifdef FM_LIBRESPOT
    fm_webapi_login_stop();
#endif
}

- (void)librespotPause
{
#ifdef FM_LIBRESPOT
    fm_librespot_pause();
#endif
}

- (void)librespotResume
{
#ifdef FM_LIBRESPOT
    fm_librespot_play();
#endif
}

- (void)librespotRewind
{
#ifdef FM_LIBRESPOT
    fm_librespot_seek(0);
#endif
}

- (void)loadPlaylistTracksWithLibrespot:(NSString *)playlistID offset:(NSUInteger)offset limit:(NSUInteger)limit completion:(void (^)(NSDictionary *, NSError *))completion
{
#ifdef FM_LIBRESPOT
    // Not on _librespotQueue: looking up every track takes a while and shouldn't hold up playback.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *json = NULL;
        char *listError = NULL;
        NSDictionary *page = nil;
        NSError *error = nil;
        if (fm_librespot_playlist_tracks([playlistID UTF8String], (uint32_t)offset, (uint32_t)limit, &json, &listError)) {
            NSData *data = [NSData dataWithBytes:json length:strlen(json)];
            fm_librespot_free_string(json);
            page = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (![page isKindOfClass:[NSDictionary class]]) page = nil;
        } else {
            NSString *message = listError ? [NSString stringWithUTF8String:listError] : @"Unknown error";
            fm_librespot_free_string(listError);
            error = [NSError errorWithDomain:@"librespot" code:10 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Can't load playlist", NSLocalizedDescriptionKey: message}];
        }
        if (!page && !error) error = [NSError errorWithDomain:@"librespot" code:11 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Can't load playlist", NSLocalizedDescriptionKey: @"librespot sent an unreadable playlist."}];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(page, error);
        });
    });
#else
    if (completion) completion(nil, [NSError errorWithDomain:@"librespot" code:0 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Not available", NSLocalizedDescriptionKey: @"This build doesn't include librespot."}]);
#endif
}

- (void)librespotSeekToPosition:(NSTimeInterval)position
{
#ifdef FM_LIBRESPOT
    fm_librespot_seek((uint32_t)MAX(position * 1000, 0));
#endif
}

- (FMSpotifyClient *)spotifyClient
{
    return _spotifyClient ? _spotifyClient : (_spotifyClient = [FMSpotifyClient spotifyClient]);
}

- (FMLucidaClient *)lucidaClient
{
    return _lucidaClient ? _lucidaClient : (_lucidaClient = [FMLucidaClient lucidaClient]);
}

@end
