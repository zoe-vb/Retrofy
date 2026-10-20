//
//  FMTheme.h
//  FoxMusic
//
//  Dark Spotify look: charcoal bars and lists, white text, Spotify green accents.
//

#import <UIKit/UIKit.h>

typedef enum {
    FMIconPlay,
    FMIconPause,
    FMIconNext,
    FMIconPrevious,
    FMIconShuffle,
    FMIconRepeat,
    FMIconRepeatOne,
    // Marks the playing track in lists.
    FMIconSpeaker,
    // Add to Liked Songs: a plus in a circle. Added: a check in a filled circle.
    FMIconAdd,
    FMIconAdded,
} FMIcon;

@interface FMTheme : NSObject

+ (UIColor *)greenColor;
+ (UIColor *)backgroundColor;
+ (UIColor *)cellColor;
+ (UIColor *)separatorColor;
+ (UIColor *)textColor;
+ (UIColor *)secondaryTextColor;

// Sets up UIAppearance for the bars, call once at launch.
+ (void)applyAppearance;

// Dark background, white labels and green buttons for a plain screen built in the storyboard.
+ (void)styleView:(UIView *)view;

+ (void)styleTableView:(UITableView *)tableView;
// Drawn in code, so no image files are needed.
+ (UIImage *)icon:(FMIcon)icon size:(CGFloat)size color:(UIColor *)color;

// Square list thumbnails with slightly rounded corners, like modern Spotify.
+ (UIImage *)thumbnailFromImage:(UIImage *)image size:(CGFloat)size;
+ (UIImage *)playlistPlaceholderWithSize:(CGFloat)size;
// Spotify's Liked Songs cover: a purple to green gradient with a white heart.
+ (UIImage *)likedSongsArtworkWithSize:(CGFloat)size;

// From tableView:willDisplayCell:forRowAtIndexPath:, iOS 6 ignores cell colors set any earlier.
+ (void)styleCell:(UITableViewCell *)cell;

// A two line cell for a track, made in code so it looks the same in every list.
+ (UITableViewCell *)trackCellForTableView:(UITableView *)tableView;
// The playing track is green, like Spotify. Call after styleCell:.
+ (void)styleCell:(UITableViewCell *)cell playing:(BOOL)playing;

@end
