//
//  FMNowPlayingViewController.m
//  FoxMusic
//
//  Spotify's iOS 6 Now Playing screen: the cover with a seek bar, shuffle and repeat across its top,
//  and the playback controls and volume below it. Built in code, so both storyboards share it.
//

#import "FMNowPlayingViewController.h"

#import <MediaPlayer/MediaPlayer.h>

#import "FMPlayer.h"
#import "FMSpotifyLibrary.h"
#import "FMTheme.h"
#import "FMTrackActions.h"

// Room the controls below the cover need at least, the cover shrinks to leave it.
static const CGFloat FMNowPlayingMinimumControlsHeight = 108;
static const CGFloat FMNowPlayingScrubberHeight = 44;

@interface FMNowPlayingViewController ()
{
    UIImageView *_coverView;
    UIActivityIndicatorView *_spinner;

    UIView *_scrubberBar;
    UIButton *_repeatButton;
    UIButton *_shuffleButton;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    UISlider *_slider;
    // While the slider is dragged, it isn't moved along with playback.
    BOOL _scrubbing;

    UIImageView *_controlsView;
    UIButton *_previousButton;
    UIButton *_playButton;
    UIButton *_nextButton;
    MPVolumeView *_volumeView;

    UILabel *_titleLabel;
    UILabel *_subtitleLabel;

    NSTimer *_progressTimer;

    UIButton *_likeButton;
    // The track whose Liked Songs state was asked for, so it's only asked once.
    FMSpotifyTrack *_checkedTrack;
}
@end

@implementation FMNowPlayingViewController

+ (NSString *)stringFromTime:(NSTimeInterval)time
{
    int seconds = (int)round(MAX(time, 0));
    return [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
}

- (id)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.hidesBottomBarWhenPushed = YES;
        self.title = @"Now Playing";
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)buttonWithIcon:(FMIcon)icon size:(CGFloat)size action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:[FMTheme icon:icon size:size color:[FMTheme textColor]] forState:UIControlStateNormal];
    [button setImage:[FMTheme icon:icon size:size color:[FMTheme greenColor]] forState:UIControlStateHighlighted];
    button.showsTouchWhenHighlighted = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)timeLabelWithAlignment:(NSTextAlignment)alignment
{
    UILabel *label = [[UILabel alloc] init];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = [FMTheme textColor];
    label.font = [UIFont boldSystemFontOfSize:12];
    label.textAlignment = alignment;
    label.text = @"0:00";
    return label;
}

- (UIImage *)sliderThumbImage
{
    CGFloat size = 16;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size + 4, size + 4), NO, 0);
    CGContextSetShadowWithColor(UIGraphicsGetCurrentContext(), CGSizeMake(0, 1), 2, [UIColor blackColor].CGColor);
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 1, size, size)] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _coverView = [[UIImageView alloc] init];
    _coverView.contentMode = UIViewContentModeScaleAspectFill;
    _coverView.clipsToBounds = YES;
    _coverView.backgroundColor = [FMTheme cellColor];
    _coverView.userInteractionEnabled = YES;
    [self.view addSubview:_coverView];

    // Swiping the cover changes tracks.
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(next:)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    [_coverView addGestureRecognizer:swipeLeft];
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(previous:)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    [_coverView addGestureRecognizer:swipeRight];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [_coverView addSubview:_spinner];

    _scrubberBar = [[UIView alloc] init];
    _scrubberBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [_coverView addSubview:_scrubberBar];

    _repeatButton = [self buttonWithIcon:FMIconRepeat size:24 action:@selector(toggleRepeat:)];
    _shuffleButton = [self buttonWithIcon:FMIconShuffle size:24 action:@selector(toggleShuffle:)];
    _elapsedLabel = [self timeLabelWithAlignment:NSTextAlignmentRight];
    _remainingLabel = [self timeLabelWithAlignment:NSTextAlignmentLeft];

    _slider = [[UISlider alloc] init];
    [_slider setThumbImage:[self sliderThumbImage] forState:UIControlStateNormal];
    [_slider setMinimumTrackTintColor:[FMTheme greenColor]];
    [_slider setMaximumTrackTintColor:[UIColor colorWithWhite:0.35 alpha:1]];
    [_slider addTarget:self action:@selector(sliderTouchDown:) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    for (UIView *view in @[_repeatButton, _elapsedLabel, _slider, _remainingLabel, _shuffleButton]) [_scrubberBar addSubview:view];

    _controlsView = [[UIImageView alloc] init];
    _controlsView.userInteractionEnabled = YES;
    [self.view addSubview:_controlsView];

    _previousButton = [self buttonWithIcon:FMIconPrevious size:36 action:@selector(previous:)];
    _playButton = [self buttonWithIcon:FMIconPlay size:44 action:@selector(togglePlayPause:)];
    _nextButton = [self buttonWithIcon:FMIconNext size:36 action:@selector(next:)];
    for (UIView *view in @[_previousButton, _playButton, _nextButton]) [_controlsView addSubview:view];

    _volumeView = [[MPVolumeView alloc] init];
    [_controlsView addSubview:_volumeView];

    // Track and album in the navigation bar, like Spotify.
    UIView *titleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
    titleView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 3, 200, 18)];
    _titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _titleLabel.textColor = [FMTheme textColor];
    _titleLabel.shadowColor = [UIColor blackColor];
    _titleLabel.shadowOffset = CGSizeMake(0, -1);
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 21, 200, 16)];
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [FMTheme secondaryTextColor];
    for (UILabel *label in @[_titleLabel, _subtitleLabel]) {
        label.backgroundColor = [UIColor clearColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [titleView addSubview:label];
    }
    self.navigationItem.titleView = titleView;

    // Add to Liked Songs, or once added: remove, or add to a playlist. Like modern Spotify's + button.
    _likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _likeButton.frame = CGRectMake(0, 0, 40, 40);
    _likeButton.showsTouchWhenHighlighted = YES;
    [_likeButton addTarget:self action:@selector(likeTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_likeButton];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerStateDidChange:) name:FMPlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateLikeButton) name:FMSpotifyLibraryDidChangeNotification object:nil];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGSize size = self.view.bounds.size;

    CGFloat coverSide = MIN(size.width, size.height - FMNowPlayingMinimumControlsHeight);
    _coverView.frame = CGRectMake(round((size.width - coverSide) / 2), 0, coverSide, coverSide);
    _spinner.center = CGPointMake(coverSide / 2, coverSide / 2);

    _scrubberBar.frame = CGRectMake(0, 0, coverSide, FMNowPlayingScrubberHeight);
    _repeatButton.frame = CGRectMake(0, 0, 44, FMNowPlayingScrubberHeight);
    _shuffleButton.frame = CGRectMake(coverSide - 44, 0, 44, FMNowPlayingScrubberHeight);
    _elapsedLabel.frame = CGRectMake(44, 0, 38, FMNowPlayingScrubberHeight);
    _remainingLabel.frame = CGRectMake(coverSide - 44 - 42, 0, 42, FMNowPlayingScrubberHeight);
    CGFloat sliderX = CGRectGetMaxX(_elapsedLabel.frame) + 6;
    _slider.frame = CGRectMake(sliderX, 0, CGRectGetMinX(_remainingLabel.frame) - 6 - sliderX, FMNowPlayingScrubberHeight);

    CGFloat controlsHeight = size.height - coverSide;
    _controlsView.frame = CGRectMake(0, coverSide, size.width, controlsHeight);
    if (!_controlsView.image || _controlsView.image.size.height != controlsHeight) {
        _controlsView.image = [self controlsBackgroundWithHeight:controlsHeight];
    }

    CGFloat volumeHeight = 44;
    CGFloat buttonsCenterY = round((controlsHeight - volumeHeight) / 2) + 4;
    CGFloat centerX = round(size.width / 2);
    _playButton.frame = CGRectMake(centerX - 36, buttonsCenterY - 30, 72, 60);
    _previousButton.frame = CGRectMake(centerX - 36 - 30 - 64, buttonsCenterY - 26, 64, 52);
    _nextButton.frame = CGRectMake(centerX + 36 + 30, buttonsCenterY - 26, 64, 52);
    _volumeView.frame = CGRectMake(24, controlsHeight - volumeHeight + 8, size.width - 48, 24);
}

- (UIImage *)controlsBackgroundWithHeight:(CGFloat)height
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, height), YES, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGFloat components[] = {0.17, 1, 0.05, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
    CGContextDrawLinearGradient(UIGraphicsGetCurrentContext(), gradient, CGPointZero, CGPointMake(0, height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    [[UIColor colorWithWhite:0.3 alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, 1, 1));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsZero];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAll];
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // The timer keeps this controller alive until it's invalidated.
    [_progressTimer invalidate];
    _progressTimer = nil;
}

#pragma mark - Updating

- (void)playerStateDidChange:(NSNotification *)notification
{
    [self updateAll];
}

- (void)updateAll
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    FMSpotifyTrack *track = player.currentTrack;

    _titleLabel.text = track.name;
    NSString *subtitle = track.artistName ?: track.album.name ?: player.contextName;
    _subtitleLabel.text = player.isPreview ? [NSString stringWithFormat:@"Preview · %@", subtitle ?: @""] : subtitle;
    _coverView.image = player.coverImage;

    if (player.isLoading) [_spinner startAnimating];
    else [_spinner stopAnimating];

    FMIcon playIcon = player.isPlaying ? FMIconPause : FMIconPlay;
    [_playButton setImage:[FMTheme icon:playIcon size:44 color:[FMTheme textColor]] forState:UIControlStateNormal];
    [_playButton setImage:[FMTheme icon:playIcon size:44 color:[FMTheme greenColor]] forState:UIControlStateHighlighted];

    UIColor *shuffleColor = player.shuffle ? [FMTheme greenColor] : [FMTheme secondaryTextColor];
    [_shuffleButton setImage:[FMTheme icon:FMIconShuffle size:24 color:shuffleColor] forState:UIControlStateNormal];

    FMIcon repeatIcon = player.repeatMode == FMPlayerRepeatOne ? FMIconRepeatOne : FMIconRepeat;
    UIColor *repeatColor = player.repeatMode == FMPlayerRepeatOff ? [FMTheme secondaryTextColor] : [FMTheme greenColor];
    [_repeatButton setImage:[FMTheme icon:repeatIcon size:24 color:repeatColor] forState:UIControlStateNormal];

    [self updateLikeButton];
    [self updateProgress];
}

- (void)updateLikeButton
{
    FMSpotifyTrack *track = [[FMPlayer sharedPlayer] currentTrack];
    NSNumber *saved = [[FMSpotifyLibrary sharedLibrary] isTrackSaved:track];
    if (!saved && track && ![track isEqual:_checkedTrack]) {
        _checkedTrack = track;
        [[FMSpotifyLibrary sharedLibrary] checkTrackSaved:track completion:^(BOOL isSaved, NSError *error){
            [self updateLikeButton];
        }];
    }
    BOOL isSaved = [saved boolValue];
    [_likeButton setImage:[FMTheme icon:isSaved ? FMIconAdded : FMIconAdd size:26 color:isSaved ? [FMTheme greenColor] : [FMTheme textColor]] forState:UIControlStateNormal];
    _likeButton.enabled = track.identifier != nil;
}

- (void)likeTapped:(id)sender
{
    [[FMTrackActions sharedActions] likeTappedForTrack:[[FMPlayer sharedPlayer] currentTrack] inViewController:self];
}

- (void)updateProgress
{
    if (_scrubbing) return;
    FMPlayer *player = [FMPlayer sharedPlayer];
    NSTimeInterval duration = player.duration;
    _slider.enabled = duration > 0 && !player.isLoading;
    _slider.value = duration > 0 ? player.position / duration : 0;
    [self showTimesForPosition:player.position duration:duration];
}

- (void)showTimesForPosition:(NSTimeInterval)position duration:(NSTimeInterval)duration
{
    _elapsedLabel.text = [FMNowPlayingViewController stringFromTime:position];
    _remainingLabel.text = [@"-" stringByAppendingString:[FMNowPlayingViewController stringFromTime:duration - position]];
}

#pragma mark - Actions

- (void)togglePlayPause:(id)sender
{
    [[FMPlayer sharedPlayer] togglePlayPause];
}

- (void)next:(id)sender
{
    [[FMPlayer sharedPlayer] next];
}

- (void)previous:(id)sender
{
    [[FMPlayer sharedPlayer] previous];
}

- (void)toggleShuffle:(id)sender
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    player.shuffle = !player.shuffle;
}

// Off, all, one, like Spotify.
- (void)toggleRepeat:(id)sender
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    player.repeatMode = (player.repeatMode + 1) % 3;
}

- (void)sliderTouchDown:(UISlider *)slider
{
    _scrubbing = YES;
}

- (void)sliderValueChanged:(UISlider *)slider
{
    NSTimeInterval duration = [[FMPlayer sharedPlayer] duration];
    [self showTimesForPosition:slider.value * duration duration:duration];
}

- (void)sliderTouchUp:(UISlider *)slider
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    [player seekToPosition:slider.value * player.duration];
    _scrubbing = NO;
    [self updateProgress];
}

@end

@implementation UIViewController (FMNowPlaying)

- (void)updateNowPlayingButton
{
    if (![[FMPlayer sharedPlayer] currentTrack]) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    if (self.navigationItem.rightBarButtonItem.action == @selector(showNowPlaying:)) return;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Now Playing" style:UIBarButtonItemStyleBordered target:self action:@selector(showNowPlaying:)];
}

- (void)showNowPlaying:(id)sender
{
    if ([self.navigationController.topViewController isKindOfClass:[FMNowPlayingViewController class]]) return;
    [self.navigationController pushViewController:[[FMNowPlayingViewController alloc] init] animated:YES];
}

@end
