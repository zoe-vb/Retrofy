//
//  fmlibrespot.h
//  FoxMusic
//
//  C interface of the Rust librespot bridge (FMLibrespot/). Requires Spotify Premium.
//  There is one librespot session per process; call fm_librespot_init before anything else.
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
    /// FoxMusic is no longer announced on the network, detail is the reason.
    FM_LIBRESPOT_EVENT_DISCOVERY_STOPPED = 9,
    /// A log message from librespot, detail is the message.
    FM_LIBRESPOT_EVENT_LOG = 10,
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

/// Announces FoxMusic as a Spotify Connect device on the local network. Picking it in the Spotify app on
/// another device logs in and sends FM_LIBRESPOT_EVENT_LOGGED_IN or FM_LIBRESPOT_EVENT_LOGIN_FAILED.
bool fm_librespot_start_discovery(const char *device_name, char **error_out);
void fm_librespot_stop_discovery(void);

/// Gets a Web API access token, logging in with the saved login if needed. Comes from login5, which has
/// no scope list; the comma separated scopes are only used by the keymaster fallback. Blocks. Free the
/// token with fm_librespot_free_string.
bool fm_librespot_web_api_token(const char *scopes, char **token_out, uint32_t *expires_in_out, char **error_out);

/// Logs out and forgets the saved login.
void fm_librespot_logout(void);

/// Loads a track by URI, e.g. "spotify:track:4cOdK2wGLETKBW3PvgPWqT", playing through an Audio Queue
/// (set up AVAudioSession first). Blocks if it has to log in first.
bool fm_librespot_load(const char *uri, bool start_playing, uint32_t position_ms, char **error_out);
void fm_librespot_play(void);
void fm_librespot_pause(void);
void fm_librespot_stop(void);
void fm_librespot_seek(uint32_t position_ms);

/// Receives the token response JSON (success) or an error message, on a background thread.
typedef void (*fm_webapi_login_callback)(void *context, bool success, const char *detail);

/// Web API login for FoxMusic's own client ID (PKCE). Serves a page on `port` on the local network with a
/// link to Spotify's login; the user pastes the address Spotify redirected to (redirect_uri, which must be
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
