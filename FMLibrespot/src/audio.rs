//! Audio output through AudioToolbox's Audio Queue Services (iOS 2+). librespot's player thread
//! writes decoded PCM into a small ring buffer, the audio queue's own thread drains it.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr;
use std::sync::{Arc, Condvar, Mutex};

use librespot::playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot::playback::convert::Converter;
use librespot::playback::decoder::AudioPacket;

const SAMPLE_RATE: f64 = 44100.0;
const CHANNELS: u32 = 2;
const BYTES_PER_FRAME: u32 = CHANNELS * 2;
const BUFFER_COUNT: usize = 3;
// About 93 ms per audio queue buffer.
const FRAMES_PER_BUFFER: u32 = 4096;
// Keep the ring buffer short (about half a second) so pausing and seeking stay responsive.
const RING_CAPACITY_SAMPLES: usize = 22050 * CHANNELS as usize;

type OSStatus = i32;
type AudioQueueRef = *mut c_void;

#[repr(C)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioQueueBuffer {
    audio_data_bytes_capacity: u32,
    audio_data: *mut c_void,
    audio_data_byte_size: u32,
    user_data: *mut c_void,
    packet_description_capacity: u32,
    packet_descriptions: *mut c_void,
    packet_description_count: u32,
}

type AudioQueueOutputCallback =
    extern "C" fn(user_data: *mut c_void, queue: AudioQueueRef, buffer: *mut AudioQueueBuffer);

#[link(name = "AudioToolbox", kind = "framework")]
extern "C" {
    fn AudioQueueNewOutput(
        format: *const AudioStreamBasicDescription,
        callback: AudioQueueOutputCallback,
        user_data: *mut c_void,
        run_loop: *mut c_void,
        run_loop_mode: *const c_void,
        flags: u32,
        queue: *mut AudioQueueRef,
    ) -> OSStatus;
    fn AudioQueueAllocateBuffer(queue: AudioQueueRef, byte_size: u32, buffer: *mut *mut AudioQueueBuffer) -> OSStatus;
    fn AudioQueueEnqueueBuffer(
        queue: AudioQueueRef,
        buffer: *mut AudioQueueBuffer,
        packet_description_count: u32,
        packet_descriptions: *const c_void,
    ) -> OSStatus;
    fn AudioQueueStart(queue: AudioQueueRef, start_time: *const c_void) -> OSStatus;
    fn AudioQueuePause(queue: AudioQueueRef) -> OSStatus;
    fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) -> OSStatus;
}

const K_AUDIO_FORMAT_LINEAR_PCM: u32 = u32::from_be_bytes(*b"lpcm");
const K_LINEAR_PCM_FORMAT_FLAG_IS_SIGNED_INTEGER: u32 = 1 << 2;
const K_LINEAR_PCM_FORMAT_FLAG_IS_PACKED: u32 = 1 << 3;

struct Ring {
    samples: VecDeque<i16>,
    closed: bool,
}

struct Shared {
    ring: Mutex<Ring>,
    space_available: Condvar,
}

extern "C" fn fill_buffer(user_data: *mut c_void, queue: AudioQueueRef, buffer: *mut AudioQueueBuffer) {
    let shared = unsafe { &*(user_data as *const Shared) };
    let buffer = unsafe { &mut *buffer };
    let capacity = (buffer.audio_data_bytes_capacity / 2) as usize;
    let output = unsafe { std::slice::from_raw_parts_mut(buffer.audio_data as *mut i16, capacity) };

    let mut ring = shared.ring.lock().unwrap_or_else(|e| e.into_inner());
    let available = ring.samples.len().min(capacity);
    for (slot, sample) in output.iter_mut().zip(ring.samples.drain(..available)) {
        *slot = sample;
    }
    drop(ring);
    shared.space_available.notify_all();

    // Play silence instead of stopping when librespot can't keep up, the queue needs a buffer back.
    output[available..].fill(0);
    buffer.audio_data_byte_size = (capacity * 2) as u32;
    unsafe { AudioQueueEnqueueBuffer(queue, buffer, 0, ptr::null()) };
}

pub struct AudioQueueSink {
    queue: AudioQueueRef,
    shared: Arc<Shared>,
    running: bool,
}

impl AudioQueueSink {
    pub fn new() -> Result<Self, OSStatus> {
        let shared = Arc::new(Shared {
            ring: Mutex::new(Ring { samples: VecDeque::with_capacity(RING_CAPACITY_SAMPLES), closed: false }),
            space_available: Condvar::new(),
        });
        let format = AudioStreamBasicDescription {
            sample_rate: SAMPLE_RATE,
            format_id: K_AUDIO_FORMAT_LINEAR_PCM,
            format_flags: K_LINEAR_PCM_FORMAT_FLAG_IS_SIGNED_INTEGER | K_LINEAR_PCM_FORMAT_FLAG_IS_PACKED,
            bytes_per_packet: BYTES_PER_FRAME,
            frames_per_packet: 1,
            bytes_per_frame: BYTES_PER_FRAME,
            channels_per_frame: CHANNELS,
            bits_per_channel: 16,
            reserved: 0,
        };

        let mut queue: AudioQueueRef = ptr::null_mut();
        // A null run loop makes the queue call fill_buffer on its own internal thread.
        let status = unsafe {
            AudioQueueNewOutput(
                &format,
                fill_buffer,
                Arc::as_ptr(&shared) as *mut c_void,
                ptr::null_mut(),
                ptr::null(),
                0,
                &mut queue,
            )
        };
        if status != 0 {
            return Err(status);
        }

        // Prime the buffers with silence so the queue starts pulling as soon as it's started.
        for _ in 0..BUFFER_COUNT {
            let mut buffer: *mut AudioQueueBuffer = ptr::null_mut();
            let status = unsafe { AudioQueueAllocateBuffer(queue, FRAMES_PER_BUFFER * BYTES_PER_FRAME, &mut buffer) };
            if status != 0 {
                unsafe { AudioQueueDispose(queue, 1) };
                return Err(status);
            }
            fill_buffer(Arc::as_ptr(&shared) as *mut c_void, queue, buffer);
        }

        Ok(Self { queue, shared, running: false })
    }
}

impl Sink for AudioQueueSink {
    fn start(&mut self) -> SinkResult<()> {
        if !self.running {
            let status = unsafe { AudioQueueStart(self.queue, ptr::null()) };
            if status != 0 {
                return Err(SinkError::StateChange(format!("AudioQueueStart failed: {status}")));
            }
            self.running = true;
        }
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        if self.running {
            unsafe { AudioQueuePause(self.queue) };
            self.running = false;
        }
        // Drop what's buffered, otherwise the old position plays briefly after a seek or new track.
        self.shared.ring.lock().unwrap_or_else(|e| e.into_inner()).samples.clear();
        self.shared.space_available.notify_all();
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let AudioPacket::Samples(samples) = packet else {
            return Ok(());
        };
        let samples = converter.f64_to_s16(&samples);

        let mut written = 0;
        while written < samples.len() {
            let mut ring = self.shared.ring.lock().unwrap_or_else(|e| e.into_inner());
            // Block librespot's decoder while the queue still has enough to play.
            while ring.samples.len() >= RING_CAPACITY_SAMPLES && !ring.closed && self.running {
                ring = self.shared.space_available.wait(ring).unwrap_or_else(|e| e.into_inner());
            }
            if ring.closed {
                return Ok(());
            }
            let free = RING_CAPACITY_SAMPLES.saturating_sub(ring.samples.len());
            if free == 0 {
                // Not running, so nothing drains the buffer. Waiting would deadlock, drop the rest instead.
                return Ok(());
            }
            let end = (written + free).min(samples.len());
            ring.samples.extend(&samples[written..end]);
            written = end;
        }
        Ok(())
    }
}

impl Drop for AudioQueueSink {
    fn drop(&mut self) {
        self.shared.ring.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        self.shared.space_available.notify_all();
        // Dispose immediately, so fill_buffer can't run anymore once `shared` is freed.
        unsafe { AudioQueueDispose(self.queue, 1) };
    }
}
