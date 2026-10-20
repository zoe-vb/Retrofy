//
//  FMTableViewController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 17/07/25.
//  Copyright (c) 2025 Lasse Lauwerys. All rights reserved.
//

#import "FMTableViewController.h"
#import "FMTheme.h"
#import "FMPlayer.h"
#import "FMNowPlayingViewController.h"
#import "FMSpotifyLibrary.h"

@implementation FMTableViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    _appDelegate = (FMAppDelegate *)[[UIApplication sharedApplication] delegate];
    [FMTheme styleTableView:self.tableView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerStateDidChange:) name:FMPlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(likedSongsDidChange:) name:FMSpotifyLibraryDidChangeNotification object:nil];
}

- (void)likedSongsDidChange:(NSNotification *)notification
{
    if (self.isViewLoaded) [self.tableView reloadData];
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
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [FMTheme styleCell:cell];
}

@end
