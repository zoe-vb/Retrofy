//
//  FMSpotifyTrackViewController.h
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "FMViewController.h"

@interface FMSpotifyTrackViewController : FMViewController
{
    // Whether this screen started its track through librespot, so Play resumes instead of reloading.
    BOOL _hasStartedLibrespot;
}

@property FMSpotifyTrack *track;

@property IBOutlet UIImageView *albumCoverImageView;

@property IBOutlet UIToolbar *toolbar;
@property IBOutlet UIBarButtonItem *playButtonItem;
@property UIImage *albumCoverImage;

// Track and album names over the bottom of the cover, like Spotify's now playing screen.
@property UILabel *trackNameLabel;
@property UILabel *albumNameLabel;

- (IBAction)play:(id)sender;
- (IBAction)pause:(id)sender;
- (IBAction)rewind:(id)sender;

@end
