//! Web API login for FoxMusic's own Spotify client ID, with the authorization code flow and PKCE.
//!
//! iOS 6's Safari can't open Spotify's login page (accounts.spotify.com only offers AES-GCM), so the
//! login happens in a browser on another device: FoxMusic serves a small page on the local network with
//! a link to Spotify's login. Spotify then redirects to `redirect_uri` (http://127.0.0.1:...), which
//! won't load on that device, and the user pastes that address back into the page. FoxMusic exchanges
//! the code for tokens over rustls and hands the token response to the app.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use base64::Engine;
use rand::Rng;
use sha2::{Digest, Sha256};

/// Receives the token response JSON (success) or an error message. Called on a background thread.
pub type FmWebApiLoginCallback = extern "C" fn(context: *mut c_void, success: bool, detail: *const c_char);

const SCOPES: &str = "user-read-private user-read-email playlist-read-private playlist-read-collaborative user-library-read";
const MAX_REQUEST_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy)]
struct Context(*mut c_void);
unsafe impl Send for Context {}

impl Context {
    fn get(self) -> *mut c_void {
        self.0
    }
}

struct Login {
    client_id: String,
    redirect_uri: String,
    verifier: String,
    state: String,
}

struct Server {
    stop: Arc<AtomicBool>,
    port: u16,
}

static SERVER: Mutex<Option<Server>> = Mutex::new(None);

fn random_string(length: usize) -> String {
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::rng();
    (0..length).map(|_| CHARSET[rng.random_range(0..CHARSET.len())] as char).collect()
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

impl Login {
    fn new(client_id: String, redirect_uri: String) -> Self {
        Self { client_id, redirect_uri, verifier: random_string(64), state: random_string(16) }
    }

    fn authorize_url(&self) -> String {
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(self.verifier.as_bytes()));
        url::Url::parse_with_params(
            "https://accounts.spotify.com/authorize",
            &[
                ("client_id", self.client_id.as_str()),
                ("response_type", "code"),
                ("redirect_uri", self.redirect_uri.as_str()),
                ("code_challenge_method", "S256"),
                ("code_challenge", challenge.as_str()),
                ("scope", SCOPES),
                ("state", self.state.as_str()),
            ],
        )
        .map(|url| url.to_string())
        .unwrap_or_default()
    }

    fn page(&self, message: Option<&str>) -> String {
        let message = message
            .map(|text| format!("<p class=\"message\">{}</p>", escape_html(text)))
            .unwrap_or_default();
        format!(
            r#"<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>FoxMusic login</title>
<style>
body {{ font-family: -apple-system, Helvetica, Arial, sans-serif; max-width: 34em; margin: 2em auto; padding: 0 16px; line-height: 1.5; color: #222; background: #fff; }}
a.button, button {{ display: inline-block; background: #1db954; color: #fff; border: 0; border-radius: 2em; padding: .6em 1.4em; font-size: 1em; text-decoration: none; cursor: pointer; }}
input {{ width: 100%; box-sizing: border-box; font-size: 1em; padding: .5em; margin: .5em 0; }}
.message {{ background: #fdecea; padding: .6em .8em; border-radius: .4em; }}
code {{ background: #f2f2f2; padding: 0 .2em; }}
</style></head><body>
<h1>Log FoxMusic in to the Web API</h1>
{message}
<p><b>1.</b> <a class="button" href="{authorize}" target="_blank" rel="noopener">Log in with Spotify</a></p>
<p><b>2.</b> After you agree, the browser goes to <code>{redirect}</code>, which won't load. That's expected. Copy the whole address from the address bar.</p>
<form method="post" action="/code">
<p><b>3.</b> Paste it here:</p>
<input name="url" placeholder="{redirect}?code=..." autocomplete="off" autofocus>
<button type="submit">Finish login</button>
</form>
</body></html>"#,
            message = message,
            authorize = escape_html(&self.authorize_url()),
            redirect = escape_html(&self.redirect_uri),
        )
    }

    /// Takes the pasted redirect address (or just the code) and exchanges it for tokens.
    fn finish(&self, pasted: &str) -> Result<String, String> {
        let pasted = pasted.trim();
        let (code, state) = match url::Url::parse(pasted) {
            Ok(redirected) => {
                let mut code = None;
                let mut state = None;
                for (key, value) in redirected.query_pairs() {
                    match key.as_ref() {
                        "code" => code = Some(value.into_owned()),
                        "state" => state = Some(value.into_owned()),
                        "error" => return Err(format!("Spotify said: {value}")),
                        _ => {}
                    }
                }
                (code.ok_or("That address has no code in it, copy the whole address after logging in.")?, state)
            }
            Err(_) if !pasted.is_empty() && !pasted.contains(' ') => (pasted.to_string(), None),
            Err(_) => return Err("Paste the address the browser went to after logging in.".into()),
        };
        if state.as_deref().is_some_and(|state| state != self.state) {
            return Err("That login belongs to an older page. Reload this page and log in again.".into());
        }

        let body = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("grant_type", "authorization_code")
            .append_pair("code", &code)
            .append_pair("redirect_uri", &self.redirect_uri)
            .append_pair("client_id", &self.client_id)
            .append_pair("code_verifier", &self.verifier)
            .finish();
        let response = crate::http::request(
            "POST",
            "https://accounts.spotify.com/api/token",
            &[("Content-Type", "application/x-www-form-urlencoded")],
            body.as_bytes(),
        )?;
        let text = String::from_utf8_lossy(&response.body).into_owned();
        if response.status == 200 && text.contains("refresh_token") {
            Ok(text)
        } else {
            Err(format!("Spotify refused the login (HTTP {}): {}", response.status, text))
        }
    }
}

struct Request {
    method: String,
    path: String,
    body: Vec<u8>,
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn read_request(stream: &mut TcpStream) -> Option<Request> {
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
    let mut raw = Vec::new();
    let mut buffer = [0u8; 4096];
    let header_end = loop {
        let read = stream.read(&mut buffer).ok()?;
        if read == 0 {
            return None;
        }
        raw.extend_from_slice(&buffer[..read]);
        if let Some(end) = find(&raw, b"\r\n\r\n") {
            break end;
        }
        if raw.len() > MAX_REQUEST_BYTES {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&raw[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next()?.split(' ');
    let method = request_line.next()?.to_string();
    let path = request_line.next()?.to_string();
    let content_length = lines
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0)
        .min(MAX_REQUEST_BYTES);
    let mut body = raw[header_end + 4..].to_vec();
    while body.len() < content_length {
        let read = stream.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&buffer[..read]);
    }
    body.truncate(content_length);
    Some(Request { method, path, body })
}

fn respond(stream: &mut TcpStream, status: &str, html: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{html}",
        html.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

const DONE_PAGE: &str = r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>FoxMusic login</title></head>
<body style="font-family: -apple-system, Helvetica, Arial, sans-serif; max-width: 34em; margin: 2em auto; padding: 0 16px;">
<h1>FoxMusic is logged in</h1><p>You can close this page and go back to your iPhone.</p></body></html>"#;

/// Handles one connection. Returns true once the login is complete.
fn handle(stream: &mut TcpStream, login: &Login, context: Context, callback: FmWebApiLoginCallback) -> bool {
    let Some(request) = read_request(stream) else { return false };
    match (request.method.as_str(), request.path.split('?').next().unwrap_or("")) {
        ("GET", "/") => {
            respond(stream, "200 OK", &login.page(None));
            false
        }
        ("POST", "/code") => {
            let pasted = url::form_urlencoded::parse(&request.body)
                .find(|(key, _)| key == "url")
                .map(|(_, value)| value.into_owned())
                .unwrap_or_default();
            match login.finish(&pasted) {
                Ok(token_json) => {
                    respond(stream, "200 OK", DONE_PAGE);
                    let detail = CString::new(token_json).unwrap_or_default();
                    callback(context.get(), true, detail.as_ptr());
                    true
                }
                Err(message) => {
                    log::warn!("Web API login failed: {message}");
                    respond(stream, "200 OK", &login.page(Some(&message)));
                    false
                }
            }
        }
        _ => {
            respond(stream, "404 Not Found", "<!doctype html><title>Not found</title>Not found");
            false
        }
    }
}

/// Serves the login page on `port` on all network interfaces until the login is done or
/// fm_webapi_login_stop is called. `redirect_uri` must be registered for the client ID in Spotify's
/// developer dashboard.
#[no_mangle]
pub unsafe extern "C" fn fm_webapi_login_start(
    client_id: *const c_char,
    redirect_uri: *const c_char,
    port: u16,
    context: *mut c_void,
    callback: FmWebApiLoginCallback,
    error_out: *mut *mut c_char,
) -> bool {
    let fail = |message: String| {
        if !error_out.is_null() {
            *error_out = CString::new(message).unwrap_or_default().into_raw();
        }
        false
    };
    let (Some(client_id), Some(redirect_uri)) = (
        (!client_id.is_null()).then(|| CStr::from_ptr(client_id).to_string_lossy().into_owned()),
        (!redirect_uri.is_null()).then(|| CStr::from_ptr(redirect_uri).to_string_lossy().into_owned()),
    ) else {
        return fail("Missing client ID or redirect URI".into());
    };

    let mut server = SERVER.lock().unwrap_or_else(|e| e.into_inner());
    if server.as_ref().is_some_and(|server| !server.stop.load(Ordering::SeqCst)) {
        return true;
    }

    let listener = match TcpListener::bind(("0.0.0.0", port)) {
        Ok(listener) => listener,
        Err(error) => return fail(format!("Couldn't open port {port}: {error}")),
    };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let context = Context(context);
    let login = Login::new(client_id, redirect_uri);

    thread::Builder::new()
        .name("fm-webapi-login".into())
        .spawn(move || {
            for stream in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = stream else { continue };
                if handle(&mut stream, &login, context, callback) {
                    thread_stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        })
        .map_err(|error| error.to_string())
        .map(|_| {
            *server = Some(Server { stop, port });
            true
        })
        .unwrap_or_else(|message| fail(message))
}

#[no_mangle]
pub extern "C" fn fm_webapi_login_stop() {
    if let Some(server) = SERVER.lock().unwrap_or_else(|e| e.into_inner()).take() {
        if !server.stop.swap(true, Ordering::SeqCst) {
            // Wake the accept() so the thread sees the flag and closes the port.
            let _ = TcpStream::connect(("127.0.0.1", server.port));
        }
    }
}
