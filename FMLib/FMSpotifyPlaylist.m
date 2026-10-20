//
//  FMSpotifyPlaylist.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyPlaylist.h"

@implementation FMSpotifyPlaylist

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (self) {
        self.description = [dictionary objectForKey:@"description"];
        self.name = [dictionary objectForKey:@"name"];

        self.identifier = [dictionary objectForKey:@"id"];
        NSDictionary *tracks = [dictionary objectForKey:@"tracks"];
        if (![tracks isKindOfClass:[NSDictionary class]]) tracks = [dictionary objectForKey:@"items"];
        self.tracks = [FMSpotifyTrackArray trackArrayWithDictionary:[tracks isKindOfClass:[NSDictionary class]] ? tracks : nil];
        
        NSArray *images = [dictionary objectForKey:@"images"];
        NSDictionary *smallestImage = nil;
        if ([images isKindOfClass:[NSArray class]]) for (NSDictionary *image in images) {
            if (![image isKindOfClass:[NSDictionary class]] || ![[image objectForKey:@"url"] isKindOfClass:[NSString class]]) continue;
            id width = [image objectForKey:@"width"], smallestWidth = [smallestImage objectForKey:@"width"];
            if (!smallestImage || ([width isKindOfClass:[NSNumber class]] && [smallestWidth isKindOfClass:[NSNumber class]] && [width intValue] < [smallestWidth intValue])) smallestImage = image;
        }
        if (smallestImage) self.imageURL = [NSURL URLWithString:[smallestImage objectForKey:@"url"]];

        if (![self.name isKindOfClass:[NSString class]]) self.name = nil;
        if (![self.description isKindOfClass:[NSString class]]) self.description = nil;
    }
    return self;
}

- (NSUInteger)hash
{
    return [[self identifier] hash];
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[FMSpotifyPlaylist class]] && [[self identifier] isEqualToString:[object identifier]];
}

- (void)extendTracksWithDictionary:(NSDictionary *)dictionary
{
    self.tracks = [FMSpotifyTrackArray trackArrayWithDictionary:[dictionary objectForKey:@"tracks"]];
}

+ (FMSpotifyPlaylist *)playlistFromDictionary:(NSDictionary *const)dictionary
{
    return [[FMSpotifyPlaylist alloc] initWithDictionary:dictionary];
}

@end
