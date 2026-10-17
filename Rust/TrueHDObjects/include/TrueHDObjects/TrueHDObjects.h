// Copyright 2026 PrismCore contributors. Apache License 2.0 (see Rust/TrueHDObjects/LICENSE-APACHE).
//
// TrueHD Atmos objects decoded (truehdd's `truehd` crate) and rendered to 7.1.4 by the ETSI
// TS 103 448 source panner. TrueHD only. One session per stream; not thread-safe, so every
// call on a session is serialized by the caller.
#ifndef TRUEHD_OBJECTS_H
#define TRUEHD_OBJECTS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Output channels, in kAudioChannelLayoutTag_Atmos_7_1_4 order: L R C LFE Ls Rs Lb Rb Tfl Tfr Tbl Tbr.
#define TRUEHD_OBJECTS_CHANNELS 12
/// Output (and the only accepted input) sample rate.
#define TRUEHD_OBJECTS_SAMPLE_RATE 48000

/// What a session is delivering (`truehd_objects_mode`).
enum {
    /// Nothing decoded yet, or audio held until the first object metadata.
    TRUEHD_OBJECTS_PENDING = 0,
    /// Atmos objects rendered to 7.1.4, heights included.
    TRUEHD_OBJECTS_RENDERED = 1,
    /// The stream's own channel presentation (at most 7.1) with silent heights: the fallback for
    /// a stream without objects or with metadata the renderer does not place.
    TRUEHD_OBJECTS_BED = 2,
};

typedef struct TrueHDObjects TrueHDObjects;

/// Receives `frames` frames of interleaved Float32 PCM, TRUEHD_OBJECTS_CHANNELS per frame, valid
/// only during the call. Return 0 to continue; anything else stops the session.
typedef int32_t (*TrueHDObjectsPCM)(void *context, const float *interleaved, uint32_t frames);

/// A new session, or NULL when allocation failed.
TrueHDObjects *truehd_objects_open(void);

/// Feeds TrueHD bytes of this track only, starting at a major sync. `end` nonzero flushes the
/// last 2 ms. Output is contiguous from the first sample of the first access unit: held,
/// concealed and fallback audio all keep their length, so sample N of the output is sample N of
/// the input. Returns 0, or -1 after which the session accepts nothing (see `message`).
int32_t truehd_objects_push(TrueHDObjects *session, const uint8_t *data, size_t length, int32_t end,
                            TrueHDObjectsPCM callback, void *context);

/// One of the TRUEHD_OBJECTS_* modes.
uint32_t truehd_objects_mode(const TrueHDObjects *session);

/// Copies the error, or else the reason the session fell back to the bed, as UTF-8 with a
/// terminating zero (empty when neither). Returns the capacity the whole text needs.
size_t truehd_objects_message(const TrueHDObjects *session, char *buffer, size_t capacity);

/// Frees a session; NULL is ignored.
void truehd_objects_close(TrueHDObjects *session);

#ifdef __cplusplus
}
#endif

#endif
