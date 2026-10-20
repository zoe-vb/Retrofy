//
//  FMSpotifyTrackArray.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyTrackArray.h"


@implementation FMSpotifyTrackArray

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    // The superclass initializer already calls addItemsFromDictionary:, which adds the tracks.
    self = [super initWithDictionary:dictionary];
    if (self) {
//        self.href = [NSURL URLWithString:[dictionary objectForKey:@"href"]];
//        NSArray *items = [dictionary objectForKey:@"items"];
//        NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:[items count]];
//        
//        for (NSDictionary *item in items)
//            [tracks addObject:[FMSpotifyTrack trackFromDictionary:item]];
//        
//        [[self items] addObjectsFromArray:tracks];
//        [self setItems:]?
    }
    return self;
}

- (id)initWithURL:(NSURL *)url
{
    self = [super init];
    if (self) self.href = url;
    return self;
}

- (FMSpotifyContinuableArray *)addItemsFromDictionary:(NSDictionary *)dictionary
{
    if (![dictionary isKindOfClass:[NSDictionary class]]) return self;
    
    // Search results wrap the paging object in "tracks", use its href/next for continuing.
    NSDictionary *tracksDictinary = [dictionary objectForKey:@"tracks"];
    if ([tracksDictinary isKindOfClass:[NSDictionary class]]) dictionary = tracksDictinary;
    
    [super setURLsFromDictionary:dictionary]; // set next and href more safely to avoid exception
    
    NSArray *items = [dictionary objectForKey:@"items"];
    if (![items isKindOfClass:[NSArray class]]) return self;
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:[items count]];
    
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *trackDictionary = [item objectForKey:@"track"];
        if (!trackDictionary) trackDictionary = [item objectForKey:@"item"];
        if (!trackDictionary) trackDictionary = item;
        // Removed or unavailable tracks come back as "track": null.
        if (![trackDictionary isKindOfClass:[NSDictionary class]]) continue;
        [tracks addObject:[FMSpotifyTrack trackFromDictionary:trackDictionary]];
    }
    
//    self.items = [NSArray arrayWithArray:tracks];
    [[self items] addObjectsFromArray:tracks];
    return self;
}

- (FMSpotifyTrack *)itemAtIndex:(NSUInteger)index
{
    return [super itemAtIndex:index];
}

+ (FMSpotifyTrackArray *)trackArrayWithDictionary:(NSDictionary *)dictionary
{
    return [[FMSpotifyTrackArray alloc] initWithDictionary:dictionary];
}

//+ (FMSpotifyTrackArray *)trackArrayWithURL:(NSURL *)url
//{
//    return [[FMSpotifyTrackArray alloc] initWithURL:url];
//}

@end
