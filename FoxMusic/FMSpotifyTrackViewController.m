//
//  FMSpotifyTrackViewController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//



#import "FMSpotifyTrackViewController.h"
#import "FMTheme.h"

@implementation FMSpotifyTrackViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [FMTheme backgroundColor];

    UIImageView *coverView = self.albumCoverImageView;
    coverView.backgroundColor = [FMTheme cellColor];
    coverView.clipsToBounds = YES;

    // Darkens the bottom of the cover so the names stay readable on light artwork.
    CGFloat shadeHeight = 120;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, shadeHeight), NO, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGFloat components[] = {0, 0, 0, 0.85};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGContextDrawLinearGradient(UIGraphicsGetCurrentContext(), gradient, CGPointZero, CGPointMake(0, shadeHeight), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    UIImageView *shadeView = [[UIImageView alloc] initWithImage:UIGraphicsGetImageFromCurrentImageContext()];
    UIGraphicsEndImageContext();
    shadeView.frame = CGRectMake(0, coverView.bounds.size.height - shadeHeight, coverView.bounds.size.width, shadeHeight);
    shadeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [coverView addSubview:shadeView];

    self.trackNameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, shadeHeight - 58, shadeView.bounds.size.width - 32, 26)];
    self.trackNameLabel.font = [UIFont boldSystemFontOfSize:20];
    self.trackNameLabel.textColor = [FMTheme textColor];
    self.trackNameLabel.shadowColor = [UIColor blackColor];
    self.trackNameLabel.shadowOffset = CGSizeMake(0, 1);

    self.albumNameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, shadeHeight - 30, shadeView.bounds.size.width - 32, 18)];
    self.albumNameLabel.font = [UIFont systemFontOfSize:14];
    self.albumNameLabel.textColor = [FMTheme secondaryTextColor];

    for (UILabel *label in @[self.trackNameLabel, self.albumNameLabel]) {
        label.backgroundColor = [UIColor clearColor];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [shadeView addSubview:label];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    FMSpotifyTrack *track = [[self appDelegate] selectedTrack];
    [self setTrack:track];
    [self setTitle:[track name]];
    
    // Load album cover image safely
    @try {
        NSURL *imageURL = [[track album] imageURL];
        if (imageURL) {
            [[[self appDelegate] spotifyClient] getDataFromURL:imageURL withCallback:^(NSData *data){
                if (data && data.length > 0) {
                    UIImage *image = [UIImage imageWithData:data];
                    if (image) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self setAlbumCoverImage:image];
                            [[self albumCoverImageView] setImage:image];
                        });
                    }
                }
            }];
        }
    }
    @catch (NSException *exception) {
        NSLog(@"Error loading album cover: %@", exception.reason);
        [[self appDelegate] displayException:exception];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    FMSpotifyTrack *track = [[self appDelegate] selectedTrack];
    [self setTitle:track.name];
    [self.trackNameLabel setText:track.name];
    [self.albumNameLabel setText:track.album.name];
}

- (void)play:(id)sender
{
    // Resuming a paused librespot track.
    if ([[self appDelegate] librespotActive] && [[[self appDelegate] selectedTrack] isEqual:self.track] && _hasStartedLibrespot) {
        [[self appDelegate] librespotResume];
        [self setToolbarPlaying:YES];
        return;
    }

    if ([[self appDelegate] librespotAvailable] && self.track) {
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        [self updateNowPlayingInfo];
        [[self appDelegate] playTrackWithLibrespot:self.track completion:^(NSError *error){
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            if (error) {
                // Fall back to the 30 second preview.
                NSLog(@"librespot failed, playing the preview instead: %@", error.localizedDescription);
                [[self appDelegate] displayError:error];
                [self playPreview];
            } else {
                _hasStartedLibrespot = YES;
                [self setToolbarPlaying:YES];
            }
        }];
        return;
    }

    [self playPreview];
}

- (void)updateNowPlayingInfo
{
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
    if (self.albumCoverImage) [nowPlayingInfo setObject:[[MPMediaItemArtwork alloc] initWithImage:self.albumCoverImage] forKey:MPMediaItemPropertyArtwork];
    [nowPlayingInfo setObject:self.track.name ?: @"Unknown Track" forKey:MPMediaItemPropertyTitle];
    [nowPlayingInfo setObject:_appDelegate.selectedPlaylist.name ?: self.track.album.name ?: @"Unknown Album" forKey:MPMediaItemPropertyAlbumTitle];
    if (self.track.duration > 0) [nowPlayingInfo setObject:@(self.track.duration) forKey:MPMediaItemPropertyPlaybackDuration];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
}

- (void)setToolbarPlaying:(BOOL)playing
{
    NSMutableArray *items = [NSMutableArray arrayWithArray:[[self toolbar] items]];
    if (items.count > 2) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:playing ? UIBarButtonSystemItemPause : UIBarButtonSystemItemPlay target:self action:playing ? @selector(pause:) : @selector(play:)];
        [item setStyle:UIBarButtonItemStyleBordered];
        [items replaceObjectAtIndex:2 withObject:item];
        [[self toolbar] setItems:items animated:YES];
    }
}

- (void)playPreview
{
    @try {
        // Validate track exists
        if (!self.track) {
            NSLog(@"No track selected for playback");
            return;
        }

        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        
        // Download track with proper error handling
        [[[self appDelegate] spotifyClient] downloadTrack:[self track] callback:^(NSData *musicData){
            
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    // Validate audio data
                    if (!musicData || musicData.length == 0) {
                        NSLog(@"No audio data received");
                        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                        [_appDelegate displayError:[NSError errorWithDomain:@"no_audio" code:1003 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Playback failed", NSLocalizedDescriptionKey: @"No audio could be loaded for this track."}]];
                        return;
                    }
                    
                    NSError *error;
                    
                    // Setup audio session
                    AVAudioSession *session = [AVAudioSession sharedInstance];
                    [session setCategory:AVAudioSessionCategoryPlayback
                             withOptions:AVAudioSessionCategoryOptionDuckOthers|AVAudioSessionCategoryOptionAllowBluetooth
                                   error:&error];
                    if (error) {
                        NSLog(@"Audio session setup error: %@", error.localizedDescription);
                        [_appDelegate displayError:error];
                        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                        return;
                    }
                    
                    // Begin receiving remote control events
                    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
                    
                    // Setup now playing info safely
                    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
                    
                    if (self.albumCoverImage) {
                        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithImage:self.albumCoverImage];
                        [nowPlayingInfo setObject:artwork forKey:MPMediaItemPropertyArtwork];
                    }
                    
                    NSString *title = self.track.name ?: @"Unknown Track";
                    [nowPlayingInfo setObject:title forKey:MPMediaItemPropertyTitle];
                    
                    NSString *albumTitle = _appDelegate.selectedPlaylist.name ?: self.track.album.name ?: @"Unknown Album";
                    [nowPlayingInfo setObject:albumTitle forKey:MPMediaItemPropertyAlbumTitle];
                    
                    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
                    
                    // Create audio player with error handling
                    AVAudioPlayer *audioPlayer = [[AVAudioPlayer alloc] initWithData:musicData error:&error];
                    if (error) {
                        NSLog(@"Audio player creation error: %@", error.localizedDescription);
                        [_appDelegate displayError:error];
                        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                        return;
                    }
                    
                    // Set audio player and prepare
                    [[self appDelegate] setAudioPlayer:audioPlayer];
                    [audioPlayer prepareToPlay];
                    
                    // Activate audio session
                    [session setActive:YES error:&error];
                    if (error) {
                        NSLog(@"Audio session activation error: %@", error.localizedDescription);
                        [_appDelegate displayError:error];
                        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                        return;
                    }
                    
                    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                    [self play];
                    
                } @catch (NSException *exception) {
                    NSLog(@"Exception during audio playback setup: %@", exception.reason);
                    [[self appDelegate] displayException:exception];
                    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                }
            });
        }];
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in play method: %@", exception.reason);
        [[self appDelegate] displayException:exception];
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
}

- (void)play
{
    @try {
        AVAudioPlayer *audioPlayer = [[self appDelegate] audioPlayer];
        if (!audioPlayer) {
            NSLog(@"No audio player available");
            return;
        }
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *items = [NSMutableArray arrayWithArray:[[self toolbar] items]];
            
            if (items.count > 2) {
                UIBarButtonItem *pauseButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(pause:)];
                [pauseButtonItem setStyle:UIBarButtonItemStyleBordered];
                [items replaceObjectAtIndex:2 withObject:pauseButtonItem];
                [[self toolbar] setItems:items animated:YES];
            }
        });
        
        // Play audio
        BOOL success = [audioPlayer play];
        if (!success) {
            NSLog(@"Failed to start audio playback");
        }
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in play method: %@", exception.reason);
        [[self appDelegate] displayException:exception];
    }
}

- (void)pause
{
    if ([[self appDelegate] librespotActive]) {
        [[self appDelegate] librespotPause];
        [self setToolbarPlaying:NO];
        return;
    }

    @try {
        AVAudioPlayer *audioPlayer = [[self appDelegate] audioPlayer];
        if (audioPlayer) {
            [audioPlayer pause];
        }
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *items = [NSMutableArray arrayWithArray:[[self toolbar] items]];
            
            if (items.count > 2) {
                UIBarButtonItem *playButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(play:)];
                [playButtonItem setStyle:UIBarButtonItemStyleBordered];
                [items replaceObjectAtIndex:2 withObject:playButtonItem];
                [[self toolbar] setItems:items animated:YES];
            }
        });
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in pause method: %@", exception.reason);
        [[self appDelegate] displayException:exception];
    }
}

- (void)pause:(id)sender
{
    [self pause];
}

- (void)rewind:(id)sender
{
    if ([[self appDelegate] librespotActive]) {
        [[self appDelegate] librespotRewind];
        return;
    }

    @try {
        AVAudioPlayer *audioPlayer = [[self appDelegate] audioPlayer];
        if (audioPlayer) {
            [audioPlayer setCurrentTime:0];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in rewind method: %@", exception.reason);
        [[self appDelegate] displayException:exception];
    }
}

@end
