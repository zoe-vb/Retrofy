//
//  FMSpotifyPlaylist.h
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "FMSpotifyTrackArray.h"

@interface FMSpotifyPlaylist : NSObject

@property NSString *description;
@property NSString *href;
@property NSString *identifier;
@property NSString *name;
@property FMSpotifyTrackArray *tracks;
@property NSString *color;
// The smallest cover image, for thumbnails.
@property NSURL *imageURL;
@property NSString *ownerID;
// Daily Mixes, Discover Weekly and the like. The Web API refuses their tracks to development mode apps.
@property (readonly, nonatomic) BOOL isSpotifyMade;

- (id)initWithDictionary:(NSDictionary *)dictionary;

//- (NSUInteger)hash;
//- (BOOL)isEqual:(id)object;

+ (FMSpotifyPlaylist *)playlistFromDictionary:(NSDictionary *const)dictionary;

@end
