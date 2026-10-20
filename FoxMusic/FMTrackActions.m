//
//  FMTrackActions.m
//  FoxMusic
//
//  The + / ✓ button shown for a track on Now Playing and in track lists, like modern Spotify: + adds the
//  track to Liked Songs, ✓ offers removing it or adding it to a playlist.
//

#import "FMTrackActions.h"

#import <QuartzCore/QuartzCore.h>

#import "FMSpotifyLibrary.h"
#import "FMTheme.h"

// The user's playlists to add a track to.
@interface FMPlaylistPickerViewController : UITableViewController

@property FMSpotifyPlaylistArray *playlists;
// Called with the chosen playlist, or nil when cancelled.
@property (copy) void (^completion)(FMSpotifyPlaylist *playlist);

@end

@implementation FMPlaylistPickerViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Add to Playlist";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel:)];
    [FMTheme styleTableView:self.tableView];

    FMSpotifyClient *client = [(FMAppDelegate *)[[UIApplication sharedApplication] delegate] spotifyClient];
    [client getUserPlaylistsAndWhenSuccess:^(FMSpotifyPlaylistArray *playlists){
        self.playlists = playlists;
        [self.tableView reloadData];
        [self loadMore];
    } whenError:^(NSError *error){
        [(FMAppDelegate *)[[UIApplication sharedApplication] delegate] displayError:error];
    }];
}

- (void)loadMore
{
    if ([self.playlists isComplete] || ![self.playlists hasNext]) return;
    FMSpotifyClient *client = [(FMAppDelegate *)[[UIApplication sharedApplication] delegate] spotifyClient];
    [client continueArray:self.playlists withOnSuccess:^(FMSpotifyContinuableArray *playlists){
        [self.tableView reloadData];
        [self loadMore];
    } onError:^(NSError *error){}];
}

- (void)cancel:(id)sender
{
    if (self.completion) self.completion(nil);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.playlists.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FMPlaylistPickerCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FMPlaylistPickerCell"];
    cell.textLabel.text = [[self.playlists itemAtIndex:indexPath.row] name];
    cell.imageView.image = [FMTheme playlistPlaceholderWithSize:36];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [FMTheme styleCell:cell];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.completion) self.completion([self.playlists itemAtIndex:indexPath.row]);
}

@end

@interface FMTrackActions ()
{
    // What the open action sheet or alert is about.
    FMSpotifyTrack *_track;
    __weak UIViewController *_viewController;
}
@end

@implementation FMTrackActions

+ (FMTrackActions *)sharedActions
{
    static FMTrackActions *sharedActions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedActions = [[FMTrackActions alloc] init];
    });
    return sharedActions;
}

+ (UIImage *)likeImageForSaved:(BOOL)saved size:(CGFloat)size
{
    return [FMTheme icon:saved ? FMIconAdded : FMIconAdd size:size color:saved ? [FMTheme greenColor] : [FMTheme secondaryTextColor]];
}

+ (void)showLikeButtonInCell:(UITableViewCell *)cell forTrack:(FMSpotifyTrack *)track target:(id)target action:(SEL)action
{
    UIButton *button = [cell.accessoryView isKindOfClass:[UIButton class]] ? (UIButton *)cell.accessoryView : nil;
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(0, 0, 40, 44);
        button.showsTouchWhenHighlighted = YES;
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = button;
    }
    NSNumber *saved = [[FMSpotifyLibrary sharedLibrary] isTrackSaved:track];
    if (!saved) [[FMSpotifyLibrary sharedLibrary] requestSavedStateForTracks:track ? @[track] : @[]];
    button.hidden = !saved || !track.identifier;
    [button setImage:[self likeImageForSaved:[saved boolValue] size:22] forState:UIControlStateNormal];
}

+ (NSIndexPath *)indexPathForLikeButtonEvent:(UIEvent *)event inTableView:(UITableView *)tableView
{
    UITouch *touch = [[event allTouches] anyObject];
    return touch ? [tableView indexPathForRowAtPoint:[touch locationInView:tableView]] : nil;
}

- (void)likeTappedForTrack:(FMSpotifyTrack *)track inViewController:(UIViewController *)viewController
{
    if (!track.identifier) return;
    _track = track;
    _viewController = viewController;

    if ([[[FMSpotifyLibrary sharedLibrary] isTrackSaved:track] boolValue]) {
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:track.name delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Remove from Liked Songs" otherButtonTitles:@"Add to Playlist…", nil];
        sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
        [sheet showInView:viewController.view.window ?: viewController.view];
        return;
    }
    [[FMSpotifyLibrary sharedLibrary] setTrack:track saved:YES completion:^(NSError *error){
        if (error) [self showError:error];
        else [self showToast:@"Added to Liked Songs" inViewController:viewController];
    }];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    FMSpotifyTrack *track = _track;
    UIViewController *viewController = _viewController;
    if (buttonIndex == actionSheet.cancelButtonIndex || !track) return;
    if (buttonIndex == actionSheet.destructiveButtonIndex) {
        [[FMSpotifyLibrary sharedLibrary] setTrack:track saved:NO completion:^(NSError *error){
            if (error) [self showError:error];
            else [self showToast:@"Removed from Liked Songs" inViewController:viewController];
        }];
        return;
    }
    [self showPlaylistPickerForTrack:track inViewController:viewController];
}

- (void)showPlaylistPickerForTrack:(FMSpotifyTrack *)track inViewController:(UIViewController *)viewController
{
    if (!viewController) return;
    FMPlaylistPickerViewController *picker = [[FMPlaylistPickerViewController alloc] initWithStyle:UITableViewStylePlain];
    __weak UIViewController *weakViewController = viewController;
    picker.completion = ^(FMSpotifyPlaylist *playlist){
        [weakViewController dismissViewControllerAnimated:YES completion:nil];
        if (!playlist) return;
        [[FMSpotifyLibrary sharedLibrary] addTrack:track toPlaylist:playlist completion:^(NSError *error){
            if (error) [self showError:error];
            else [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name ?: @"playlist"] inViewController:weakViewController];
        }];
    };
    [viewController presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
}

- (void)showError:(NSError *)error
{
    if (error.code == FMSpotifyLibraryNeedsLoginErrorCode) {
        [[[UIAlertView alloc] initWithTitle:error.localizedFailureReason message:error.localizedDescription delegate:self cancelButtonTitle:@"Not Now" otherButtonTitles:@"Log In Again", nil] show];
        return;
    }
    [(FMAppDelegate *)[[UIApplication sharedApplication] delegate] displayError:error];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    [[FMSpotifyLibrary sharedLibrary] logOutOfWebAPI];
    // The login page is on the Playlists tab.
    UITabBarController *tabBarController = (UITabBarController *)[[[[UIApplication sharedApplication] delegate] window] rootViewController];
    if ([tabBarController isKindOfClass:[UITabBarController class]]) tabBarController.selectedIndex = 0;
}

- (void)showToast:(NSString *)message inViewController:(UIViewController *)viewController
{
    UIView *view = viewController.view;
    if (!view || !message) return;

    UILabel *toast = [[UILabel alloc] init];
    toast.text = message;
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    toast.textColor = [FMTheme textColor];
    toast.font = [UIFont boldSystemFontOfSize:14];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 6;
    toast.layer.masksToBounds = YES;
    toast.alpha = 0;

    // bounds, not frame: a table view's bounds move along with scrolling.
    CGRect bounds = view.bounds;
    CGSize size = [message sizeWithFont:toast.font];
    CGFloat width = MIN(size.width + 28, bounds.size.width - 32);
    toast.frame = CGRectMake(round(CGRectGetMidX(bounds) - width / 2), CGRectGetMaxY(bounds) - 150, width, 34);
    [view addSubview:toast];

    [UIView animateWithDuration:0.2 animations:^{
        toast.alpha = 1;
    } completion:^(BOOL finished){
        [UIView animateWithDuration:0.4 delay:1.6 options:0 animations:^{
            toast.alpha = 0;
        } completion:^(BOOL done){
            [toast removeFromSuperview];
        }];
    }];
}

@end
