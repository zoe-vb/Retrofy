//
//  FMSearchDisplayController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 4/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSearchViewController.h"
#import "FMTheme.h"
#import "FMPlayer.h"
#import "FMNowPlayingViewController.h"
#import "FMSpotifyLibrary.h"
#import "FMTrackActions.h"

@implementation FMSearchViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [FMTheme backgroundColor];
    [FMTheme styleTableView:self.searchResultTableView];
    [FMTheme styleTableView:self.searchDisplayController.searchResultsTableView];
    [self.searchBar setPlaceholder:@"Search Spotify"];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerStateDidChange:) name:FMPlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerStateDidChange:) name:FMSpotifyLibraryDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateNowPlayingButton];
}

- (void)playerStateDidChange:(NSNotification *)notification
{
    [self updateNowPlayingButton];
    [self.searchResultTableView reloadData];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [FMTheme styleCell:cell];
    FMSpotifyTrack *track = [[self tracks] itemAtIndex:[indexPath row]];
    [FMTheme styleCell:cell playing:[track isEqual:[[FMPlayer sharedPlayer] currentTrack]]];
    [FMTrackActions showLikeButtonInCell:cell forTrack:track target:self action:@selector(likeButtonTapped:event:)];
}

- (void)likeButtonTapped:(UIButton *)button event:(UIEvent *)event
{
    // Results can be in the search display controller's table too.
    UITableView *tableView = (UITableView *)button.superview;
    while (tableView && ![tableView isKindOfClass:[UITableView class]]) tableView = (UITableView *)tableView.superview;
    NSIndexPath *indexPath = [FMTrackActions indexPathForLikeButtonEvent:event inTableView:tableView ?: self.searchResultTableView];
    if (indexPath) [[FMTrackActions sharedActions] likeTappedForTrack:[[self tracks] itemAtIndex:indexPath.row] inViewController:self];
}

// Like Spotify, tapping a result plays it and the results after it, and opens Now Playing.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_appDelegate setSelectedTrack:[[self tracks] itemAtIndex:[indexPath row]]];
    [[FMPlayer sharedPlayer] playTracks:[self tracks] startingAtIndex:[indexPath row] contextName:@"Search"];
    [self showNowPlaying:nil];
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender
{
    return ![identifier isEqualToString:@"openSearchTrackResultSegue"];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    NSLog(@"This dood want u to search!!: %@", searchText);
//    [[_appDelegate spotifyClient] search:searchText withOnSuccess:^(FMSpotifyTrackArray *tracks){
//        [self setTracks:tracks];
//        [[self searchResultTableView] reloadData];
//    } onError:^(NSError *error){
//        [_appDelegate displayError:error];
//    }];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    @try {
        [super prepareForSegue:segue sender:sender];
        if ([segue.identifier isEqualToString:@"openSearchTrackResultSegue"]) {
            FMSpotifyTrack *track = [self.tracks itemAtIndex:[[self searchResultTableView] indexPathForSelectedRow].row];
            [_appDelegate setSelectedTrack:track];
        }
    } @catch (NSException *exception) {
        [_appDelegate displayException:exception];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [[self tracks] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [FMTheme trackCellForTableView:tableView];
    
    FMSpotifyTrack *track = [[self tracks] itemAtIndex:[indexPath row]];
    @try {
        [[cell textLabel] setText:[track name]];
        NSString *duration = [FMNowPlayingViewController stringFromTime:[track duration]];
        [[cell detailTextLabel] setText:(track.artistName ?: track.album.name) ? [NSString stringWithFormat:@"%@ · %@", track.artistName ?: track.album.name, duration] : duration];
    } @catch (NSException *exception) {
        [_appDelegate displayException:exception];
    }
    return cell;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    
    [[_appDelegate spotifyClient] search:[searchBar text] withOnSuccess:^(FMSpotifyTrackArray *tracks){
        [self setTracks:tracks];
        [[self searchResultTableView] reloadData];
    } onError:^(NSError *error){
        [_appDelegate displayError:error];
    }];
}

//- (void)cancelSearch:(id)sender
//{
//    [[[self searchBar] ]
//}

@end
