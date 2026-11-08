use std::{
    io::{self, Read, Seek, SeekFrom, Write},
    os::{fd::FromRawFd, unix::net::UnixStream},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use http::{header, HeaderMap, HeaderValue, Method};
use protobuf::{CodedInputStream, CodedOutputStream};

use crate::{http_client::HttpClientError, Error, FileId, Session};

const VERSION: i32 = 5;
const MAX_CHUNK: usize = 24 * 1024;

type License = ([u8; 16], [u8; 4]);

unsafe extern "C" {
    fn fm_playplay_copy_build_token(output: *mut u8);
    fn fm_playplay_spawn(fd: *mut i32, pid: *mut i32) -> i32;
    fn fm_playplay_stop(pid: i32);
}

pub struct PlayPlayDecoder {
    stream: UnixStream,
    pid: i32,
    failed: bool,
}

impl PlayPlayDecoder {
    pub async fn open(session: &Session, file: FileId) -> Result<Self, String> {
        let license = tokio::time::timeout(Duration::from_secs(20), request(session, file))
            .await.map_err(|_| "license request timed out")??;
        tokio::task::spawn_blocking(move || Self::start(license))
            .await.map_err(|_| "decoder task stopped")?
            .map_err(|error| format!("decoder setup failed: {error}"))
    }

    fn start((protected, companion): License) -> io::Result<Self> {
        let (mut fd, mut pid) = (-1, -1);
        let error = unsafe { fm_playplay_spawn(&mut fd, &mut pid) };
        if error != 0 {
            return Err(io::Error::from_raw_os_error(error));
        }
        let mut decoder = Self {
            stream: unsafe { UnixStream::from_raw_fd(fd) },
            pid,
            failed: false,
        };
        decoder.stream.write_all(&[21, 0, 0, 0, 1])?;
        decoder.stream.write_all(&protected)?;
        decoder.stream.write_all(&companion)?;
        decoder.read_reply(&mut [])?;
        Ok(decoder)
    }

    fn read_reply(&mut self, output: &mut [u8]) -> io::Result<()> {
        let mut reply = [0; 5];
        self.stream.read_exact(&mut reply)?;
        let size = u32::from_le_bytes([reply[0], reply[1], reply[2], reply[3]]);
        if reply[4] != 0 || size as usize != output.len() + 1 {
            return Err(io::Error::other(format!("invalid PlayPlay helper reply (status {})", reply[4])));
        }
        self.stream.read_exact(output)
    }

    fn decrypt(&mut self, offset: u64, bytes: &mut [u8]) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::other("PlayPlay decoder stopped"));
        }
        let size = (bytes.len() as u32 + 9).to_le_bytes();
        let mut header = [0; 13];
        header[..4].copy_from_slice(&size);
        header[4] = 2;
        header[5..].copy_from_slice(&offset.to_le_bytes());
        let result = self.stream.write_all(&header)
            .and_then(|_| self.stream.write_all(bytes))
            .and_then(|_| self.read_reply(bytes));
        if let Err(error) = &result {
            self.failed = true;
            warn!("PlayPlay decoder stream failed: {error}");
        }
        result
    }

    pub fn reader<T>(self, reader: T) -> PlayPlayReader<T> {
        PlayPlayReader { reader, decoder: self, offset: 0 }
    }
}

impl Drop for PlayPlayDecoder {
    fn drop(&mut self) {
        unsafe { fm_playplay_stop(self.pid) };
    }
}

pub struct PlayPlayReader<T> {
    reader: T,
    decoder: PlayPlayDecoder,
    offset: u64,
}

impl<T: Read> Read for PlayPlayReader<T> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        let limit = output.len().min(MAX_CHUNK);
        let size = self.reader.read(&mut output[..limit])?;
        if size > 0 {
            self.decoder.decrypt(self.offset, &mut output[..size])?;
            self.offset += size as u64;
        }
        Ok(size)
    }
}

impl<T: Seek> Seek for PlayPlayReader<T> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.offset = self.reader.seek(pos)?;
        Ok(self.offset)
    }
}

async fn request(session: &Session, file: FileId) -> Result<License, String> {
    let file_hex = file.to_base16().map_err(|_| "file ID was invalid")?;
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(|_| "needs a valid device clock")?.as_secs();
    let mut body = Vec::new();
    encode_request(session.device_id(), seconds, &mut body)
        .map_err(|_| "request could not be encoded")?;

    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/x-protobuf"));
    let response = session.spclient()
        .request(&Method::POST, &format!("/playplay/v1/key/{file_hex}"), Some(headers), Some(&body))
        .await.map_err(http_status)?;
    license_fields(&response).map_err(|_| "returned a malformed license")?
        .ok_or_else(|| "responded successfully, but the v5 license fields did not match".into())
}

fn encode_request(device_id: &str, seconds: u64, body: &mut Vec<u8>) -> protobuf::Result<()> {
    let mut request = CodedOutputStream::vec(body);
    request.write_int32(1, VERSION)?;
    let mut build_token = [0; 16];
    unsafe { fm_playplay_copy_build_token(build_token.as_mut_ptr()) };
    request.write_bytes(2, &build_token)?;
    if !device_id.is_empty() {
        request.write_bytes(3, device_id.as_bytes())?;
    }
    request.write_int32(4, 1)?; // Interactive playback.
    request.write_int32(5, 1)?; // Music track.
    request.write_uint64(6, seconds)?;
    request.flush()
}

fn license_fields(response: &[u8]) -> protobuf::Result<Option<License>> {
    let mut reply = CodedInputStream::from_bytes(response);
    let mut protected = None;
    let mut companion = None;
    while let Some(tag) = reply.read_raw_tag_or_eof()? {
        match tag {
            0x0a if protected.is_none() => {
                protected = <[u8; 16]>::try_from(reply.read_bytes()?).ok();
                if protected.is_none() { return Ok(None); }
            }
            0x12 if companion.is_none() => {
                companion = <[u8; 4]>::try_from(reply.read_bytes()?).ok();
                if companion.is_none() { return Ok(None); }
            }
            tag if matches!(tag >> 3, 1 | 2) => return Ok(None),
            tag => protobuf::rt::skip_field_for_tag(tag, &mut reply)?,
        }
    }
    Ok(protected.zip(companion))
}

fn http_status(err: Error) -> String {
    match err.error.downcast_ref::<HttpClientError>() {
        Some(HttpClientError::StatusCode(code)) => format!("failed (HTTP {})", code.as_u16()),
        None => format!("failed ({:?})", err.kind),
    }
}
