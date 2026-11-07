//
//  fmlibrespot.h
//  Retrofy
//
//  C interface of the Rust librespot bridge (FMLibrespot/). Requires Spotify Premium.
//  There is one librespot session per process; call fm_librespot_init before anything else. Once logged
//  in, the session runs a Spotify Connect device named Retrofy, and all playback goes through it.
//

#ifndef FMLIBRESPOT_H
#define FMLIBRESPOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    FM_LIBRESPOT_EVENT_PLAYING = 1,
    FM_LIBRESPOT_EVENT_PAUSED = 2,
    FM_LIBRESPOT_EVENT_STOPPED = 3,
    FM_LIBRESPOT_EVENT_END_OF_TRACK = 4,
    FM_LIBRESPOT_EVENT_UNAVAILABLE = 5,
    FM_LIBRESPOT_EVENT_LOADING = 6,
    /// Logged in through Spotify Connect, detail is the user name.
    FM_LIBRESPOT_EVENT_LOGGED_IN = 7,
    /// Spotify Connect login failed, detail is the error message.
    FM_LIBRESPOT_EVENT_LOGIN_FAILED = 8,
    /// Retrofy is no longer announced on the network, detail is the reason.
    FM_LIBRESPOT_EVENT_DISCOVERY_STOPPED = 9,
    /// A log message from librespot, detail is the message.
    FM_LIBRESPOT_EVENT_LOG = 10,
    /// The Connect device's track changed, detail is the track as Web API JSON.
    FM_LIBRESPOT_EVENT_TRACK_CHANGED = 11,
    /// A new playback position, sent every second while playing and after seeking.
    FM_LIBRESPOT_EVENT_POSITION = 12,
    /// position_ms is 1 when shuffling, 0 when not.
    FM_LIBRESPOT_EVENT_SHUFFLE = 13,
    /// position_ms is 0 (off), 1 (repeat the context) or 2 (repeat the track).
    FM_LIBRESPOT_EVENT_REPEAT = 14,
    /// position_ms is the Connect volume, 0 to 65535.
    FM_LIBRESPOT_EVENT_VOLUME = 15,
    /// Another device took over playback.
    FM_LIBRESPOT_EVENT_INACTIVE = 16,
};

/// Receives events on a background thread. `detail` (a track URI, user name or error message) is only
/// valid during the call.
typedef void (*fm_librespot_event_callback)(void *context, int event, uint32_t position_ms, const char *detail);

/// Runs a self test of the Rust runtime, free the result with fm_librespot_free_string.
char *fm_librespot_self_test(void);
void fm_librespot_free_string(char *string);

/// Sets up librespot. The login and device ID are kept in cache_dir (no audio is ever cached).
bool fm_librespot_init(const char *cache_dir, void *context, fm_librespot_event_callback event_callback, char **error_out);

/// Whether there is a session, or a saved login to restore one from.
bool fm_librespot_has_login(void);

/// Logs in with the saved login unless already logged in. Blocks while connecting, so don't call it on
/// the main thread.
bool fm_librespot_restore_session(char **error_out);

/// Announces Retrofy as a Spotify Connect device on the local network. Picking it in the Spotify app on
/// another device logs in and sends FM_LIBRESPOT_EVENT_LOGGED_IN or FM_LIBRESPOT_EVENT_LOGIN_FAILED.
bool fm_librespot_start_discovery(const char *device_name, char **error_out);
void fm_librespot_stop_discovery(void);

/// Gets a Web API access token, logging in with the saved login if needed. Comes from login5, which has
/// no scope list; the comma separated scopes are only used by the keymaster fallback. Blocks. Free the
/// token with fm_librespot_free_string.
bool fm_librespot_web_api_token(const char *scopes, char **token_out, uint32_t *expires_in_out, char **error_out);

/// Logs out and forgets the saved login.
void fm_librespot_logout(void);

/// Starts playing on Retrofy's Connect device (taking over from any other device), through an Audio Queue:
/// set up AVAudioSession first. Either context_uri (spotify:playlist:..., spotify:album:..., or
/// "spotify:collection" for Liked Songs) starting at start_uri, or track_uris_json (a JSON array of track URIs)
/// starting at start_index. Starts position_ms into that track. start_index UINT32_MAX with no start_uri lets
/// Spotify pick the first track. Blocks if it has to log in first.
bool fm_connect_play_context(const char *context_uri, const char *track_uris_json, const char *start_uri, uint32_t start_index, bool shuffle, uint32_t position_ms, char **error_out);
void fm_librespot_play(void);
void fm_librespot_pause(void);
void fm_librespot_seek(uint32_t position_ms);
void fm_connect_next(void);
void fm_connect_previous(void);
void fm_connect_set_shuffle(bool shuffle);
/// 0 off, 1 repeat the context, 2 repeat the track.
void fm_connect_set_repeat(uint32_t mode);

/// Lists up to `limit` entries of a playlist (base62 ID) from `offset`, for playlists the Web API won't list:
/// Spotify only gives development mode apps the tracks of the user's own playlists. Stores JSON shaped like a
/// Web API playlist items page in json_out, plus "next_offset" (where to continue, or null at the end).
/// Episodes, local files and tracks that can't be looked up are left out. Blocks, free the JSON with
/// fm_librespot_free_string.
bool fm_librespot_playlist_tracks(const char *playlist_id, uint32_t offset, uint32_t limit, char **json_out, char **error_out);

/// Track metadata for a JSON array of track URIs (looked up in batches), shaped like fm_librespot_playlist_tracks'
/// pages. Blocks, free the JSON with fm_librespot_free_string.
bool fm_librespot_tracks(const char *uris_json, char **json_out, char **error_out);

/// Every playlist in Your Library, including Spotify's own (Daily Mix, Your Top Songs 2023, ...) that the Web API leaves
/// out: a JSON array of {id, name, description, owner, image, length}. Blocks, free the JSON with fm_librespot_free_string.
bool fm_librespot_rootlist(char **json_out, char **error_out);

/// Spotify's lyrics for a track URI, as JSON: lyrics.syncType (LINE_SYNCED or UNSYNCED), lyrics.lines (startTimeMs,
/// words) and colors. Returns false with "No lyrics" in error_out when there are none. Blocks, free the JSON with
/// fm_librespot_free_string.
bool fm_librespot_lyrics(const char *track_uri, char **json_out, char **error_out);

/// A page of Spotify's AI DJ: a context JSON with about five picks (pages[0].tracks) and pages[0].next_page_url to
/// continue at. The commentary is SSML on the tracks' metadata (narration.intro.ssml, narration.outro.ssml); its
/// audio isn't part of the session. page_url NULL starts a session. Blocks, free the JSON with
/// fm_librespot_free_string.
bool fm_librespot_dj_session(const char *page_url, char **json_out, char **error_out);

/// Receives the token response JSON, with the client ID the user entered added as "client_id" (success), or
/// an error message, on a background thread.
typedef void (*fm_webapi_login_callback)(void *context, bool success, const char *detail);

/// Web API login with the user's own client ID (PKCE). Serves a page on `port` on the local network where the
/// user enters the client ID (client_id fills in the field and may be NULL), with a link to Spotify's login.
/// The user pastes the address Spotify redirected to (redirect_uri, which must be
/// registered for the client ID) back into the page. Stops by itself once logged in.
bool fm_webapi_login_start(const char *client_id, const char *redirect_uri, uint16_t port, void *context, fm_webapi_login_callback callback, char **error_out);
void fm_webapi_login_stop(void);

/// Blocking HTTPS request through rustls, for hosts iOS 6's TLS can't reach (accounts.spotify.com only
/// offers AES-GCM). content_type, authorization and body may be NULL. Returns true on success and stores
/// the HTTP status and body (NUL terminated, free it with fm_librespot_free_buffer). On failure stores a
/// message in error_out, free it with fm_librespot_free_string.
bool fm_https_request(const char *method,
                      const char *url,
                      const char *content_type,
                      const char *authorization,
                      const uint8_t *body,
                      size_t body_length,
                      int *status_out,
                      uint8_t **body_out,
                      size_t *body_length_out,
                      char **error_out);
/// Frees a body returned by fm_https_request, `length` is the body length it reported.
void fm_librespot_free_buffer(uint8_t *buffer, size_t length);

#endif
