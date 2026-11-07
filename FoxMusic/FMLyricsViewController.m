//
//  FMLyricsViewController.m
//  Retrofy
//
//  Spotify's lyrics for what's playing, following the song like in Spotify's apps.
//

#import "FMLyricsViewController.h"

#import "FMPlayer.h"
#import "FMSpotifyContent.h"
#import "FMTheme.h"

static const CGFloat FMLyricsFontSize = 21;
static const CGFloat FMLyricsLineSpacing = 18;
// Lines light up a little early, like in Spotify.
static const NSTimeInterval FMLyricsLeadTime = 0.15;

@interface FMLyricsViewController ()
{
    NSArray *_lines;
    NSArray *_startTimes;
    BOOL _isSynced;
    NSInteger _currentLine;
    FMSpotifyTrack *_track;
    NSTimer *_timer;
    UIColor *_textColor;
    UIColor *_highlightColor;
}
@end

@implementation FMLyricsViewController

- (id)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.hidesBottomBarWhenPushed = YES;
        self.title = @"Lyrics";
        _currentLine = NSNotFound;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.tableView.backgroundColor = [FMTheme backgroundColor];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerStateDidChange:) name:FMPlayerStateDidChangeNotification object:nil];
    [self loadLyrics];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateCurrentLine) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // The timer keeps this controller alive until it's invalidated.
    [_timer invalidate];
    _timer = nil;
}

- (void)playerStateDidChange:(NSNotification *)notification
{
    if (![[[FMPlayer sharedPlayer] currentTrack] isEqual:_track]) [self loadLyrics];
}

// Spotify sends colors as signed 32-bit ARGB.
- (UIColor *)colorFromValue:(id)value
{
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    uint32_t argb = (uint32_t)[value longLongValue];
    return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0 green:((argb >> 8) & 0xFF) / 255.0 blue:(argb & 0xFF) / 255.0 alpha:1];
}

- (void)loadLyrics
{
    FMSpotifyTrack *track = [[FMPlayer sharedPlayer] currentTrack];
    _track = track;
    [FMSpotifyContent loadLyricsForTrack:track completion:^(NSDictionary *response) {
        if (track != _track) return;
        [self showLyrics:response];
    }];
}

- (void)showLyrics:(NSDictionary *)response
{
    NSDictionary *lyrics = [response objectForKey:@"lyrics"];
    NSArray *lines = [lyrics isKindOfClass:[NSDictionary class]] ? [lyrics objectForKey:@"lines"] : nil;
    NSMutableArray *words = [NSMutableArray array];
    NSMutableArray *startTimes = [NSMutableArray array];
    if ([lines isKindOfClass:[NSArray class]]) for (NSDictionary *line in lines) {
        if (![line isKindOfClass:[NSDictionary class]]) continue;
        NSString *lineWords = [line objectForKey:@"words"];
        if (![lineWords isKindOfClass:[NSString class]]) continue;
        [words addObject:lineWords.length ? lineWords : @"♪"];
        // A string in Spotify's JSON.
        [startTimes addObject:@([[line objectForKey:@"startTimeMs"] doubleValue] / 1000)];
    }

    _lines = words;
    _startTimes = startTimes;
    _isSynced = [[lyrics objectForKey:@"syncType"] isEqual:@"LINE_SYNCED"];
    _currentLine = NSNotFound;

    NSDictionary *colors = [response objectForKey:@"colors"];
    UIColor *background = [colors isKindOfClass:[NSDictionary class]] ? [self colorFromValue:[colors objectForKey:@"background"]] : nil;
    self.tableView.backgroundColor = background ?: [FMTheme backgroundColor];
    _textColor = [colors isKindOfClass:[NSDictionary class]] ? [self colorFromValue:[colors objectForKey:@"text"]] : nil;
    _highlightColor = [colors isKindOfClass:[NSDictionary class]] ? [self colorFromValue:[colors objectForKey:@"highlightText"]] : nil;

    if (!words.count) _lines = @[@"No lyrics for this track"];
    [self.tableView reloadData];
    [self updateCurrentLine];
}

- (void)updateCurrentLine
{
    if (!_isSynced) return;
    NSTimeInterval position = [[FMPlayer sharedPlayer] position] + FMLyricsLeadTime;
    NSInteger line = NSNotFound;
    for (NSUInteger index = 0; index < _startTimes.count; index++) {
        if ([[_startTimes objectAtIndex:index] doubleValue] > position) break;
        line = index;
    }
    if (line == _currentLine) return;

    NSMutableArray *rows = [NSMutableArray array];
    if (_currentLine != NSNotFound) [rows addObject:[NSIndexPath indexPathForRow:_currentLine inSection:0]];
    if (line != NSNotFound) [rows addObject:[NSIndexPath indexPathForRow:line inSection:0]];
    _currentLine = line;
    [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
    // Not while someone is reading further on.
    if (line != NSNotFound && !self.tableView.isDragging && !self.tableView.isDecelerating) {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:line inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _lines.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CGSize size = [[_lines objectAtIndex:indexPath.row] sizeWithFont:[UIFont boldSystemFontOfSize:FMLyricsFontSize] constrainedToSize:CGSizeMake(tableView.bounds.size.width - 40, 400) lineBreakMode:NSLineBreakByWordWrapping];
    return ceil(size.height) + FMLyricsLineSpacing;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FMLyricsLine"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FMLyricsLine"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:FMLyricsFontSize];
        cell.textLabel.numberOfLines = 0;
    }
    cell.textLabel.text = [_lines objectAtIndex:indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL isCurrent = indexPath.row == _currentLine;
    cell.backgroundColor = tableView.backgroundColor;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    UIColor *textColor = _textColor ?: [FMTheme secondaryTextColor];
    if (_isSynced) cell.textLabel.textColor = isCurrent ? (_highlightColor ?: [FMTheme textColor]) : textColor;
    else cell.textLabel.textColor = _highlightColor ?: [FMTheme textColor];
}

// Tapping a line plays from it, like Spotify.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_isSynced) [[FMPlayer sharedPlayer] seekToPosition:[[_startTimes objectAtIndex:indexPath.row] doubleValue]];
}

@end
