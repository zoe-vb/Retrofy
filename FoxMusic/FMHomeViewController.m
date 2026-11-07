//
//  FMHomeViewController.m
//  Retrofy
//
//  Home: the DJ, Liked Songs, and shelves of what Spotify made for this account next to the user's playlists.
//

#import "FMHomeViewController.h"

#import "FMDJSession.h"
#import "FMNowPlayingViewController.h"
#import "FMSpotifyContent.h"
#import "FMSpotifyTrackTableViewController.h"
#import "FMTheme.h"

static const CGFloat FMHomeCoverSize = 112;
static const CGFloat FMHomeCoverSpacing = 12;
static const CGFloat FMHomeShelfHeight = 156;
static const CGFloat FMHomeRowHeight = 64;
// Above any tile's tag, which is its index.
static const NSInteger FMHomeCoverTag = 100000;
// Shelves show again from the cache, and refresh when they're this old.
static const NSTimeInterval FMHomeRefreshInterval = 600;

@interface FMHomeViewController ()
{
    // Each {title, playlists}.
    NSArray *_shelves;
    NSCache *_covers;
    NSMutableSet *_loadingCovers;
    NSDate *_lastLoad;
    BOOL _isLoading;
}
@end

@implementation FMHomeViewController

- (id)init
{
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _covers = [[NSCache alloc] init];
    _loadingCovers = [NSMutableSet set];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    for (NSString *name in @[FMWebAPIDidLogInNotification, FMLibrespotDidLogInNotification]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loginDidChange:) name:name object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    NSInteger hour = [[[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]] hour];
    self.title = hour >= 5 && hour < 12 ? @"Good morning" : hour >= 12 && hour < 18 ? @"Good afternoon" : @"Good evening";
    // The title also names the tab otherwise.
    self.navigationController.tabBarItem.title = @"Home";
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!_lastLoad || [_lastLoad timeIntervalSinceNow] < -FMHomeRefreshInterval) [self loadShelves];
}

// A reload would scroll the shelves back to their start.
- (void)playerStateDidChange:(NSNotification *)notification
{
    [self updateNowPlayingButton];
}

- (void)likedSongsDidChange:(NSNotification *)notification
{
}

- (void)loginDidChange:(NSNotification *)notification
{
    [self loadShelves];
}

#pragma mark - Loading

- (void)loadShelves
{
    FMSpotifyClient *client = [[self appDelegate] spotifyClient];
    if (_isLoading || !client.token.refreshToken) return;
    _isLoading = YES;

    // Your Library through librespot has Spotify's own playlists, the Web API has the covers of the user's.
    [client getUserPlaylistsAndWhenSuccess:^(FMSpotifyPlaylistArray *webPlaylists) {
        [self loadLibraryWithWebPlaylists:webPlaylists.items];
    } whenError:^(NSError *error) {
        [self loadLibraryWithWebPlaylists:nil];
    }];
}

- (void)loadLibraryWithWebPlaylists:(NSArray *)webPlaylists
{
    void (^finish)(NSArray *) = ^(NSArray *playlists) {
        _isLoading = NO;
        if (!playlists) return;
        _lastLoad = [NSDate date];
        _shelves = [self shelvesFromPlaylists:playlists];
        [self.tableView reloadData];
    };

    if (![[self appDelegate] librespotHasLogin]) {
        finish(webPlaylists);
        return;
    }
    [FMSpotifyContent loadLibraryPlaylists:^(NSArray *playlists, NSError *error) {
        if (!playlists) {
            finish(webPlaylists);
            return;
        }
        for (FMSpotifyPlaylist *playlist in playlists) {
            if (playlist.imageURL) continue;
            NSUInteger index = [webPlaylists indexOfObject:playlist];
            if (index != NSNotFound) playlist.imageURL = [[webPlaylists objectAtIndex:index] imageURL];
        }
        finish(playlists);
    }];
}

- (NSArray *)shelvesFromPlaylists:(NSArray *)playlists
{
    NSMutableArray *dailyMixes = [NSMutableArray array];
    NSMutableArray *madeForYou = [NSMutableArray array];
    NSMutableArray *topSongs = [NSMutableArray array];
    NSMutableArray *mixes = [NSMutableArray array];
    NSMutableArray *yours = [NSMutableArray array];
    NSArray *madeForYouNames = @[@"Discover Weekly", @"Release Radar", @"On Repeat", @"Repeat Rewind", @"daylist"];

    for (FMSpotifyPlaylist *playlist in playlists) {
        NSString *name = playlist.name ?: @"";
        if (!playlist.isSpotifyMade) [yours addObject:playlist];
        else if ([name hasPrefix:@"Daily Mix"]) [dailyMixes addObject:playlist];
        else if ([madeForYouNames containsObject:name]) [madeForYou addObject:playlist];
        else if ([name hasPrefix:@"Your Top Songs"] || [name isEqualToString:@"Your All-Time Top Songs"]) [topSongs addObject:playlist];
        else if ([name hasSuffix:@"Mix"] || [name hasSuffix:@"Radio"] || [name rangeOfString:@" + "].location != NSNotFound) [mixes addObject:playlist];
    }

    NSComparator byName = ^NSComparisonResult(FMSpotifyPlaylist *first, FMSpotifyPlaylist *second) {
        return [first.name compare:second.name options:NSNumericSearch];
    };
    [dailyMixes sortUsingComparator:byName];
    [topSongs sortUsingComparator:^NSComparisonResult(id first, id second) {
        return byName(second, first);
    }];
    [dailyMixes addObjectsFromArray:madeForYou];

    NSMutableArray *shelves = [NSMutableArray array];
    NSArray *titled = @[@[@"Made For You", dailyMixes], @[@"Your Top Songs", topSongs], @[@"Your mixes", mixes], @[@"Your playlists", yours]];
    for (NSArray *shelf in titled) {
        if ([[shelf objectAtIndex:1] count]) [shelves addObject:shelf];
    }
    return shelves;
}

#pragma mark - Covers

- (UIImage *)coverForPlaylist:(FMSpotifyPlaylist *)playlist
{
    NSURL *imageURL = playlist.imageURL;
    UIImage *cover = imageURL ? [_covers objectForKey:imageURL] : nil;
    if (cover) return cover;
    if (imageURL && ![_loadingCovers containsObject:imageURL]) {
        [_loadingCovers addObject:imageURL];
        [[[self appDelegate] spotifyClient] getDataFromURL:imageURL withCallback:^(NSData *data){
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [_loadingCovers removeObject:imageURL];
                if (!image) return;
                [_covers setObject:[FMTheme thumbnailFromImage:image size:FMHomeCoverSize] forKey:imageURL];
                [self showCover:imageURL];
            });
        }];
    }
    return [FMTheme playlistPlaceholderWithSize:FMHomeCoverSize];
}

// In place: reloading the row would lose how far its shelf is scrolled.
- (void)showCover:(NSURL *)imageURL
{
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
        if (indexPath.section == 0) continue;
        NSArray *playlists = [[_shelves objectAtIndex:indexPath.section - 1] objectAtIndex:1];
        UIScrollView *shelf = (UIScrollView *)[cell.contentView.subviews lastObject];
        for (UIButton *tile in shelf.subviews) {
            if (![tile isKindOfClass:[UIButton class]] || tile.tag >= (NSInteger)playlists.count) continue;
            FMSpotifyPlaylist *playlist = [playlists objectAtIndex:tile.tag];
            if (![playlist.imageURL isEqual:imageURL]) continue;
            UIImageView *cover = (UIImageView *)[tile viewWithTag:FMHomeCoverTag];
            cover.image = [_covers objectForKey:imageURL];
        }
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1 + _shelves.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 2 : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 ? FMHomeRowHeight : FMHomeShelfHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return section == 0 ? 0 : 36;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section == 0) return nil;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 36)];
    label.backgroundColor = [FMTheme backgroundColor];
    label.textColor = [FMTheme textColor];
    label.font = [UIFont boldSystemFontOfSize:18];
    label.text = [NSString stringWithFormat:@"   %@", [[_shelves objectAtIndex:section - 1] objectAtIndex:0]];
    return label;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FMHomeRow"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"FMHomeRow"];
        BOOL isDJ = indexPath.row == 0;
        cell.textLabel.text = isDJ ? @"DJ" : @"Liked Songs";
        cell.detailTextLabel.text = isDJ ? @"Music picked for you, with commentary" : @"Playlist";
        cell.imageView.image = isDJ ? [FMTheme djArtworkWithSize:48] : [FMTheme likedSongsArtworkWithSize:48];
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *playlists = [[_shelves objectAtIndex:indexPath.section - 1] objectAtIndex:1];

    UIScrollView *shelf = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, FMHomeShelfHeight)];
    shelf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    shelf.showsHorizontalScrollIndicator = NO;
    shelf.backgroundColor = [FMTheme backgroundColor];
    shelf.scrollsToTop = NO;
    shelf.contentSize = CGSizeMake(FMHomeCoverSpacing + playlists.count * (FMHomeCoverSize + FMHomeCoverSpacing), FMHomeShelfHeight);

    [playlists enumerateObjectsUsingBlock:^(FMSpotifyPlaylist *playlist, NSUInteger index, BOOL *stop) {
        UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
        tile.frame = CGRectMake(FMHomeCoverSpacing + index * (FMHomeCoverSize + FMHomeCoverSpacing), 0, FMHomeCoverSize, FMHomeShelfHeight);
        tile.tag = index;
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *cover = [[UIImageView alloc] initWithImage:[self coverForPlaylist:playlist]];
        cover.frame = CGRectMake(0, 0, FMHomeCoverSize, FMHomeCoverSize);
        cover.tag = FMHomeCoverTag;
        [tile addSubview:cover];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, FMHomeCoverSize + 4, FMHomeCoverSize, 32)];
        name.backgroundColor = [UIColor clearColor];
        name.textColor = [FMTheme textColor];
        name.font = [UIFont systemFontOfSize:12];
        name.numberOfLines = 2;
        name.text = playlist.name;
        [name sizeToFit];
        [tile addSubview:name];
        [shelf addSubview:tile];
    }];
    [cell.contentView addSubview:shelf];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [FMTheme styleCell:cell];
    cell.backgroundColor = [FMTheme backgroundColor];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        [[FMDJSession sharedSession] start];
        return;
    }
    [self openPlaylist:[FMSpotifyContent likedSongsPlaylist]];
}

- (void)tileTapped:(UIButton *)tile
{
    UIView *view = tile;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    NSIndexPath *indexPath = view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
    if (!indexPath || indexPath.section == 0) return;
    [self openPlaylist:[[[_shelves objectAtIndex:indexPath.section - 1] objectAtIndex:1] objectAtIndex:tile.tag]];
}

- (void)openPlaylist:(FMSpotifyPlaylist *)playlist
{
    [[self appDelegate] setSelectedPlaylist:playlist];
    [self.navigationController pushViewController:[[FMSpotifyTrackTableViewController alloc] initWithStyle:UITableViewStylePlain] animated:YES];
}

@end
