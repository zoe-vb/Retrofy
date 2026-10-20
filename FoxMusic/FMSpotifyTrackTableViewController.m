//
//  FMSpotifyTrackTableViewController.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyTrackTableViewController.h"

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
    // Playlists are paged (100 tracks per page), keep loading until every page is there.
    if ([tracks count] > 0 && ![tracks hasNext]) return;
    
    [[[self appDelegate] spotifyClient] continueArray:tracks withOnSuccess:^(FMSpotifyContinuableArray *newTracks){
        [[self tableView] reloadData];
        if ([newTracks hasNext] && tracks == self.playlist.tracks) [self loadTracks:tracks];
    } onError:^(NSError *error){
        [[self appDelegate] displayError:error];
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"trackCell" forIndexPath:indexPath];
    FMSpotifyTrack *track = [self.playlist.tracks itemAtIndex:indexPath.row];
    @try {
        [cell.textLabel setText:[track name]];
        [cell.detailTextLabel setText:[self formatDuration:[track duration]]];
    } @catch (NSException *exception) {
        [_appDelegate displayException:exception];
    }
    
    return cell;
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
