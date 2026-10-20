//
//  FMSpotifyPlaylistController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyPlaylistTableViewController.h"
#import "FMTheme.h"
#import "FMSpotifyLibrary.h"

static const CGFloat FMPlaylistThumbnailSize = 44;

@interface FMSpotifyPlaylistTableViewController ()
{
    // Thumbnails by image URL, and the URLs being downloaded.
    NSCache *_thumbnails;
    NSMutableSet *_loadingThumbnails;
}
// Liked Songs isn't a real playlist, it's shown as the first row like modern Spotify does.
@property (readonly, nonatomic) FMSpotifyPlaylist *likedSongs;
@end

@implementation FMSpotifyPlaylistTableViewController

@synthesize likedSongs = _likedSongs;

- (FMSpotifyPlaylist *)likedSongs
{
    if (!_likedSongs) {
        _likedSongs = [[FMSpotifyPlaylist alloc] init];
        _likedSongs.name = @"Liked Songs";
        _likedSongs.identifier = @"liked-songs";
        _likedSongs.tracks = [FMSpotifyTrackArray trackArrayWithDictionary:@{@"href": @"https://api.spotify.com/v1/me/tracks?limit=50"}];
    }
    return _likedSongs;
}

- (FMSpotifyPlaylist *)playlistAtRow:(NSUInteger)row
{
    return row == 0 ? self.likedSongs : [self.playlists itemAtIndex:row - 1];
}

- (UIImage *)thumbnailForPlaylist:(FMSpotifyPlaylist *)playlist
{
    if (playlist == self.likedSongs) return [FMTheme likedSongsArtworkWithSize:FMPlaylistThumbnailSize];
    NSURL *imageURL = playlist.imageURL;
    UIImage *thumbnail = imageURL ? [_thumbnails objectForKey:imageURL] : nil;
    if (thumbnail) return thumbnail;
    if (imageURL && ![_loadingThumbnails containsObject:imageURL]) {
        if (!_thumbnails) _thumbnails = [[NSCache alloc] init];
        if (!_loadingThumbnails) _loadingThumbnails = [NSMutableSet set];
        [_loadingThumbnails addObject:imageURL];
        [[[self appDelegate] spotifyClient] getDataFromURL:imageURL withCallback:^(NSData *data){
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [_loadingThumbnails removeObject:imageURL];
                if (!image) return;
                [_thumbnails setObject:[FMTheme thumbnailFromImage:image size:FMPlaylistThumbnailSize] forKey:imageURL];
                for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
                    if ([[self playlistAtRow:indexPath.row].imageURL isEqual:imageURL]) [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                }
            });
        }];
    }
    return [FMTheme playlistPlaceholderWithSize:FMPlaylistThumbnailSize];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(libraryDidChange:) name:FMSpotifyLibraryDidChangeNotification object:nil];
    
//    [self loadUserPlaylists];
}

- (void)libraryDidChange:(NSNotification *)notification
{
    // Liked Songs loads again with the change next time it's opened.
    _likedSongs = nil;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self loadUserPlaylists];
}

- (void)loadUserPlaylists
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    
    
    @try {
        NSError *error;
        [[self appDelegate].spotifyClient getUserPlaylistsAndWhenSuccess:^(FMSpotifyPlaylistArray *playlists){
            self.playlists = playlists;
            [[self tableView] reloadData];
            [self loadMorePlaylists];
        } whenError:^(NSError *error){
            [[self appDelegate] displayError:error];
        }];
        if (error) [[self appDelegate] displayError:error];
    } @catch (NSException *ex) {
        [[self appDelegate] displayException:ex];
    }
    
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

- (void)loadMorePlaylists
{
    @try {
        if (![[self playlists] isComplete] && [[self playlists] hasNext]) [[[self appDelegate] spotifyClient] continueArray:[self playlists] withOnSuccess:^(FMSpotifyContinuableArray *playlists){
            // continueArray: already appended the new page to self.playlists
            [[self tableView] reloadData];
             [self loadMorePlaylists];
        } onError:^(NSError *error){
            if(error.code != 3840)
                [[self appDelegate] displayError:error];
        }];
    } @catch (NSException *ex) {
        [[self appDelegate] displayException:ex];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSUInteger itemCount = self.playlists ? self.playlists.count : 0;
    NSLog(@"Loaded playlist count: %d", itemCount);
    return itemCount + 1;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    NSLog(@"oh bruh this one");
    
    NSUInteger selectedRowIndex = [[self tableView] indexPathForSelectedRow].row;
    FMSpotifyPlaylist *playlist = [self playlistAtRow:selectedRowIndex];
    [[self appDelegate] setSelectedPlaylist:playlist];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"playlist" forIndexPath:indexPath];
    FMSpotifyPlaylist *playlist = [self playlistAtRow:indexPath.row];
    @try {
        [cell.textLabel setText:playlist.name];
        [cell.detailTextLabel setText:playlist.description.length ? playlist.description : @"Playlist"];
        [cell.imageView setImage:[self thumbnailForPlaylist:playlist]];
    }
    @catch (NSException *ex) {
        [cell.textLabel setText:@""];
        [cell.detailTextLabel setText:@"Error"];
    }
    return cell;
}

@end
