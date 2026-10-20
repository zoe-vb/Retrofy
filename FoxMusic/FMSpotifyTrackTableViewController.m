//
//  FMSpotifyTrackTableViewController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyTrackTableViewController.h"
#import "FMPlayer.h"
#import "FMTheme.h"
#import "FMNowPlayingViewController.h"
#import "FMSpotifyLibrary.h"
#import "FMTrackActions.h"

// Tracks per librespot request, each one is looked up separately.
static const NSUInteger FMLibrespotPlaylistPageSize = 50;

// IDs of playlists being loaded through librespot, so coming back to one doesn't start a second load.
static NSMutableSet *FMLibrespotLoadingPlaylists;

@implementation FMSpotifyTrackTableViewController

- (void)viewDidAppear:(BOOL)animated
{
    @try {
        [super viewDidAppear:animated];
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
            FMSpotifyTrackArray *tracks = _appDelegate .selectedPlaylist.tracks;
        
        self.playlist = [[self appDelegate] selectedPlaylist];
        
        [self setTitle:self.playlist.name];
    
        [[self tableView] reloadData];
        [self loadTracks:tracks];
    }
    @catch (NSException *exception) {
        [[self appDelegate] displayException:exception];
    }
    @finally {
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
}


- (void)loadTracks:(FMSpotifyTrackArray *)tracks
{
    if (!tracks) return;
    if ([FMLibrespotLoadingPlaylists containsObject:self.playlist.identifier]) return;
    // Playlists are paged (100 tracks per page), keep loading until every page is there.
    if ([tracks count] > 0 && ![tracks hasNext]) return;
    
    FMSpotifyPlaylist *playlist = self.playlist;
    [[[self appDelegate] spotifyClient] continueArray:tracks withOnSuccess:^(FMSpotifyContinuableArray *newTracks){
        [[self tableView] reloadData];
        if ([newTracks hasNext] && tracks == self.playlist.tracks) [self loadTracks:tracks];
    } onError:^(NSError *error){
        // Spotify only lets Retrofy's Web API client list the user's own playlists, librespot can list any.
        BOOL isPlaylist = playlist.identifier && playlist.tracks == tracks && ![playlist.identifier isEqualToString:@"liked-songs"];
        if (error.code == 403 && isPlaylist && [[self appDelegate] librespotAvailable]) {
            [self loadTracksWithLibrespot:playlist offset:tracks.count];
            return;
        }
        [[self appDelegate] displayError:error];
    }];
}

- (void)loadTracksWithLibrespot:(FMSpotifyPlaylist *)playlist offset:(NSUInteger)offset
{
    if (!FMLibrespotLoadingPlaylists) FMLibrespotLoadingPlaylists = [NSMutableSet set];
    [FMLibrespotLoadingPlaylists addObject:playlist.identifier];
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];

    [[self appDelegate] loadPlaylistTracksWithLibrespot:playlist.identifier offset:offset limit:FMLibrespotPlaylistPageSize completion:^(NSDictionary *page, NSError *error){
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        NSNumber *nextOffset = [page objectForKey:@"next_offset"];
        if (page) [playlist.tracks addItemsFromDictionary:page];
        if (playlist == self.playlist) [[self tableView] reloadData];

        if (!error && [nextOffset isKindOfClass:[NSNumber class]]) {
            // Keeps loading after leaving the playlist, so the playlist is complete when it's opened again.
            [self loadTracksWithLibrespot:playlist offset:[nextOffset unsignedIntegerValue]];
            return;
        }
        [FMLibrespotLoadingPlaylists removeObject:playlist.identifier];
        if (error) [[self appDelegate] displayError:error];
    }];
}

- (NSString *)formatDuration:(NSTimeInterval)duration
{
    int seconds = (int)round(duration);
    return [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.playlist ? self.playlist.tracks.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [FMTheme trackCellForTableView:tableView];
    FMSpotifyTrack *track = [self.playlist.tracks itemAtIndex:indexPath.row];
    @try {
        [cell.textLabel setText:[track name]];
        NSString *duration = [self formatDuration:[track duration]];
        [cell.detailTextLabel setText:(track.artistName ?: track.album.name) ? [NSString stringWithFormat:@"%@ · %@", track.artistName ?: track.album.name, duration] : duration];
    } @catch (NSException *exception) {
        [_appDelegate displayException:exception];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    FMSpotifyTrack *track = [self.playlist.tracks itemAtIndex:indexPath.row];
    [FMTheme styleCell:cell playing:[track isEqual:[[FMPlayer sharedPlayer] currentTrack]]];
    // Everything in Liked Songs is liked, no need to ask.
    if ([self.playlist.identifier isEqualToString:@"liked-songs"] && track) [[FMSpotifyLibrary sharedLibrary] rememberTracks:@[track] saved:YES];
    [FMTrackActions showLikeButtonInCell:cell forTrack:track target:self action:@selector(likeButtonTapped:event:)];
}

- (void)likeButtonTapped:(UIButton *)button event:(UIEvent *)event
{
    NSIndexPath *indexPath = [FMTrackActions indexPathForLikeButtonEvent:event inTableView:self.tableView];
    if (indexPath) [[FMTrackActions sharedActions] likeTappedForTrack:[self.playlist.tracks itemAtIndex:indexPath.row] inViewController:self];
}

// Like Spotify, tapping a track plays the playlist from there and opens Now Playing.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_appDelegate setSelectedTrack:[self.playlist.tracks itemAtIndex:indexPath.row]];
    [[FMPlayer sharedPlayer] playTracks:self.playlist.tracks startingAtIndex:indexPath.row contextName:self.playlist.name];
    [self showNowPlaying:nil];
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender
{
    return ![identifier isEqualToString:@"openTrackSegue"];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    @try {
        [super prepareForSegue:segue sender:sender];
        if ([segue.identifier isEqualToString:@"openTrackSegue"]) {
            [_appDelegate setSelectedTrack:[[self.playlist tracks] itemAtIndex:[[self tableView] indexPathForSelectedRow].row]];
        }
    } @catch (NSException *exception) {
        [_appDelegate displayException:exception];
    }
}

@end
