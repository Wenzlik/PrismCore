// Copyright 2026 PrismCore contributors. Apache License 2.0 (see Rust/TrueHDObjects/LICENSE-APACHE).
//
// TrueHD Atmos to 7.1.4 (truehdd's `truehd` crate decodes): the objects rendered by their
// metadata (the ETSI TS 103 448 room-coordinate panner); where the render meets metadata it does
// not place, the stream's own 7.1 presentation split per frequency bin between ear level and the
// heights by where the objects' energy lies. TrueHD only. One session per stream; not
// thread-safe, so every call on a session is serialized by the caller.
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
    /// Nothing decoded yet.
    TRUEHD_OBJECTS_PENDING = 0,
    /// Atmos to 7.1.4, heights included (a channel-based immersive presentation plays as itself).
    TRUEHD_OBJECTS_RENDERED = 1,
    /// The stream's own channel presentation (at most 7.1) with silent heights: a stream without
    /// an Atmos presentation, metadata neither the render nor the split takes, or a requested bed.
    TRUEHD_OBJECTS_BED = 2,
};

typedef struct TrueHDObjects TrueHDObjects;

/// Receives `frames` frames of interleaved Float32 PCM, TRUEHD_OBJECTS_CHANNELS per frame, valid
/// only during the call. Return 0 to continue; anything else stops the session.
typedef int32_t (*TrueHDObjectsPCM)(void *context, const float *interleaved, uint32_t frames);

/// A new session, or NULL when allocation failed: the object render, with the split of the 7.1
/// presentation where the render gives up — from the stream's first sample when that is before
/// or at the first object metadata (none within 0.5 s, or metadata the render refuses), else from
/// the next major sync. Metadata the split cannot read either plays the 7.1 up to there, then the
/// bed, as 3.8 did. A split that took over for want of metadata hands back to the render at the
/// major sync after metadata it places arrives.
TrueHDObjects *truehd_objects_open(void);

/// For measurement and listening: the object render alone (the bed where it gives up).
TrueHDObjects *truehd_objects_open_exact(void);

/// For measurement and listening: the split of the 7.1 presentation alone (`.heights` in 3.8).
TrueHDObjects *truehd_objects_open_split(void);

/// The bed (silent heights, TRUEHD_OBJECTS_BED), whatever was rendering: for a host whose heights
/// chain cannot keep up. Applied at the stream's next major sync (at most 107 ms on): what plays
/// goes on until then, the split's last 32 ms come out (heights included), and the bed starts at
/// that sync, with no gap. One way; `reason` (NULL allowed) is what `truehd_objects_message`
/// reports. NULL session is ignored. The mode reads TRUEHD_OBJECTS_BED from that sync on.
void truehd_objects_request_bed(TrueHDObjects *session, const char *reason);

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
