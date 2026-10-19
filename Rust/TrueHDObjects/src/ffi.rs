// Copyright 2026 PrismCore contributors.
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! The C API (`include/TrueHDObjects/TrueHDObjects.h`). Every entry point catches panics: an
//! unwinding panic must never cross into Swift.

use crate::decode::Session;
use std::{
    ffi::{c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
};

pub type PcmCallback = unsafe extern "C" fn(*mut c_void, *const f32, u32) -> i32;

pub struct Handle {
    session: Session,
    error: String,
    ended: bool,
}

#[unsafe(no_mangle)]
pub extern "C" fn truehd_objects_open() -> *mut Handle {
    catch_unwind(|| Box::into_raw(Box::new(Handle { session: Session::default(), error: String::new(), ended: false })))
        .unwrap_or(ptr::null_mut())
}

/// The exact object render the heights split is measured against: measurement builds only
/// (`exact-render`), never a release.
#[cfg(feature = "exact-render")]
#[unsafe(no_mangle)]
pub extern "C" fn truehd_objects_open_exact() -> *mut Handle {
    catch_unwind(|| Box::into_raw(Box::new(Handle { session: Session::exact(), error: String::new(), ended: false })))
        .unwrap_or(ptr::null_mut())
}

/// # Safety
/// `handle` is live; `data` references `length` bytes; the callback must not reenter.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn truehd_objects_push(
    handle: *mut Handle,
    data: *const u8,
    length: usize,
    end: i32,
    callback: Option<PcmCallback>,
    context: *mut c_void,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_mut() }) else { return -1 };
    if handle.ended || !handle.error.is_empty() {
        return -1;
    }
    let Some(callback) = callback else {
        handle.error = "no PCM callback".into();
        return -1;
    };
    if length > 1 << 20 || (length != 0 && data.is_null()) {
        handle.error = "invalid input buffer".into();
        return -1;
    }
    let bytes = if length == 0 { &[][..] } else { unsafe { slice::from_raw_parts(data, length) } };
    let result = catch_unwind(AssertUnwindSafe(|| {
        handle.session.push(bytes, end != 0, &mut |pcm: &[f32]| {
            let frames = (pcm.len() / crate::render::CHANNELS) as u32;
            match unsafe { callback(context, pcm.as_ptr(), frames) } {
                0 => Ok(()),
                _ => Err("PCM consumer cancelled".into()),
            }
        })
    }));
    match result {
        Ok(Ok(())) => {
            handle.ended = end != 0;
            0
        }
        Ok(Err(e)) => {
            handle.error = e;
            -1
        }
        Err(_) => {
            handle.error = "decoder panic; the session has stopped".into();
            -1
        }
    }
}

/// # Safety
/// `handle` is null or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn truehd_objects_mode(handle: *const Handle) -> u32 {
    unsafe { handle.as_ref() }.map_or(0, |h| h.session.mode() as u32)
}

/// Copies the latest error, or else why the session left object rendering, as UTF-8 with a
/// terminating zero; returns the capacity that needs.
///
/// # Safety
/// `handle` is null or live; a non-null `buffer` references `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn truehd_objects_message(handle: *const Handle, buffer: *mut c_char, capacity: usize) -> usize {
    let Some(handle) = (unsafe { handle.as_ref() }) else { return 0 };
    let text = if handle.error.is_empty() {
        handle.session.fallback_reason.as_deref().unwrap_or("")
    } else {
        &handle.error
    };
    let bytes = text.as_bytes();
    if capacity > 0 && !buffer.is_null() {
        let n = bytes.len().min(capacity - 1);
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buffer.cast(), n);
            *buffer.add(n) = 0;
        }
    }
    bytes.len() + 1
}

/// # Safety
/// `handle` is null or a live session, closed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn truehd_objects_close(handle: *mut Handle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn count(context: *mut c_void, _: *const f32, frames: u32) -> i32 {
        unsafe { *(context as *mut u64) += u64::from(frames) };
        0
    }

    #[test]
    fn round_trip_rejects_misuse_without_crashing() {
        unsafe {
            let handle = truehd_objects_open();
            assert!(!handle.is_null());
            assert_eq!(truehd_objects_mode(handle), 0);
            let mut frames = 0u64;
            let context = (&mut frames as *mut u64).cast();
            // No callback: refused and reported.
            assert_eq!(truehd_objects_push(handle, ptr::null(), 0, 0, None, context), -1);
            let needed = truehd_objects_message(handle, ptr::null_mut(), 0);
            let mut text = vec![0 as c_char; needed];
            truehd_objects_message(handle, text.as_mut_ptr(), needed);
            assert!(std::ffi::CStr::from_ptr(text.as_ptr()).to_str().unwrap().contains("callback"));
            truehd_objects_close(handle);

            // An empty stream ending is an error, not a panic, and produces no PCM.
            let handle = truehd_objects_open();
            assert_eq!(truehd_objects_push(handle, ptr::null(), 0, 1, Some(count), context), 0);
            assert_eq!(frames, 0);
            truehd_objects_close(handle);
            truehd_objects_close(ptr::null_mut());

            #[cfg(feature = "exact-render")]
            {
                // The same contract for the measurement render.
                let handle = truehd_objects_open_exact();
                assert!(!handle.is_null());
                assert_eq!(truehd_objects_push(handle, ptr::null(), 0, 1, Some(count), context), 0);
                assert_eq!(frames, 0);
                assert_eq!(truehd_objects_mode(handle), 0);
                truehd_objects_close(handle);
            }
            assert_eq!(truehd_objects_mode(ptr::null()), 0);
        }
    }
}
