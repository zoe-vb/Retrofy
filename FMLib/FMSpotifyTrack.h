//
//  FMSpotifyTrack.h
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FMSpotifyAlbum.h"

@interface FMSpotifyTrack : NSObject

@property NSString *name;
@property NSTimeInterval duration;
@property NSString *identifier;
@property NSURL *previewURL;
@property FMSpotifyAlbum *album;
// Names from the track's "artists", in order.
@property NSArray *artistNames;
// The artists joined with commas, like Spotify shows them, or nil without artists.
@property (readonly, nonatomic) NSString *artistName;

- (id)initWithDictionary:(NSDictionary *)dictionary;

+ (FMSpotifyTrack *)trackFromDictionary:(NSDictionary *const)dictionary;

@end
