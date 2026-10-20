//
//  FMSpotifyItemArray.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyPlaylistArray.h"
#import "FMSpotifyPlaylist.h"

@implementation FMSpotifyPlaylistArray

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    // The superclass initializer already calls addItemsFromDictionary:, which adds the playlists.
    return [super initWithDictionary:dictionary];
}

- (FMSpotifyPlaylistArray *)addItemsFromDictionary:(NSDictionary *)dictionary
{
    [self setURLsFromDictionary:dictionary];
    
    NSArray *items = [dictionary objectForKey:@"items"];
    if ([items isKindOfClass:[NSArray class]]) for (NSDictionary *item in items)
        if ([item isKindOfClass:[NSDictionary class]])
            [[self items] addObject:[FMSpotifyPlaylist playlistFromDictionary:item]];
    
    return self;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(__unsafe_unretained id [])buffer count:(NSUInteger)len
{
    return [[self items] countByEnumeratingWithState:state objects:buffer count:len];
}

- (FMSpotifyPlaylist *)itemAtIndex:(NSUInteger)index
{
    return [super itemAtIndex:index];
}

+ (FMSpotifyPlaylistArray *)playlistArrayWithDictionary:(NSDictionary *)dictionary
{
    return [[FMSpotifyPlaylistArray alloc] initWithDictionary:dictionary];
}

@end
