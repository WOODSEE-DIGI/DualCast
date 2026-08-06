//
//  NDILib.h
//  DualCast
//
//  Minimal vendored declaration subset of the NewTek NDI(R) send-side C API,
//  matching the stable ABI exported by libndi.dylib (NDI 5/6).
//
//  Only the functions DualCast needs are declared. The struct layouts below
//  match the official SDK headers (Processing.NDI.Lib.h) — do not reorder
//  fields. A C inline helper (ndilib_send_video_bgra) is provided so Swift
//  never has to manipulate the anonymous-union struct directly.
//
//  NDI(R) is a trademark of the Vizrt Group. See libndi_licenses.txt.
//

#ifndef NDILIB_H
#define NDILIB_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Types

/// Opaque handle to an NDI sender instance.
typedef void *NDIlib_send_instance_t;

/// Creation parameters for NDIlib_send_create.
typedef struct NDIlib_send_create_t {
    /// Name of the NDI source as seen by receivers (required).
    const char *p_ndi_name;
    /// Comma-separated NDI groups (NULL = default group).
    const char *p_groups;
    /// true: NDI clocks video to the submission rate (use with synthesize).
    bool clock_video;
    /// true: NDI clocks audio to the submission rate.
    bool clock_audio;
} NDIlib_send_create_t;

/// Tally state reported by connected receivers (e.g. OBS program/preview).
typedef struct NDIlib_tally_t {
    bool on_program;
    bool on_preview;
} NDIlib_tally_t;

typedef enum NDIlib_frame_format_type_e {
    NDIlib_frame_format_type_interleaved = 0,
    NDIlib_frame_format_type_progressive = 1,
    NDIlib_frame_format_type_field_0 = 2,
    NDIlib_frame_format_type_field_1 = 3
} NDIlib_frame_format_type_e;

/// Little-endian 4-char packing, identical to NDIlib_FourCC() in the SDK.
#define NDILIB_FOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8) | \
     ((uint32_t)(uint8_t)(c) << 16) | ((uint32_t)(uint8_t)(d) << 24))

/// Video frame descriptor (v2), 72 bytes. Layout verified against the
/// official SDK (Processing.NDI.structs.h + the C++ wrapper constructors,
/// which prove line_stride and p_metadata are SEPARATE members, not a union).
/// A previous revision of this vendored header had the union wrong, which
/// caused an 8-byte heap overflow on receive — do not "simplify" it back.
typedef struct NDIlib_video_frame_v2_t {
    int xres;
    int yres;
    uint32_t FourCC;
    int frame_rate_N;
    int frame_rate_D;
    float picture_aspect_ratio;
    NDIlib_frame_format_type_e frame_format_type;
    int64_t timecode;
    uint8_t *p_data;
    union {
        int line_stride_in_bytes;   // raw/uncompressed video
        int data_size_in_bytes;     // compressed video (same ABI slot)
    };
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_video_frame_v2_t;

/// Ask NDI to synthesize timecodes from the submission clock.
#define NDILIB_SEND_TIMECODE_SYNTHESIZE INT64_MAX

// MARK: - Library lifecycle

bool NDIlib_initialize(void);
void NDIlib_destroy(void);
const char *NDIlib_version(void);
bool NDIlib_is_supported_CPU(void);

// MARK: - Sending

NDIlib_send_instance_t NDIlib_send_create(const NDIlib_send_create_t *p_create_settings);
void NDIlib_send_destroy(NDIlib_send_instance_t p_instance);
void NDIlib_send_send_video_v2(NDIlib_send_instance_t p_instance,
                               const NDIlib_video_frame_v2_t *p_video_data);
void NDIlib_send_send_video_async_v2(NDIlib_send_instance_t p_instance,
                                     const NDIlib_video_frame_v2_t *p_video_data);

/// Number of receivers currently connected. timeout 0 = return immediately.
int NDIlib_send_get_no_connections(NDIlib_send_instance_t p_instance,
                                   uint32_t timeout_in_ms);

/// Last known tally state. timeout 0 = return immediately with cached state.
void NDIlib_send_get_tally(NDIlib_send_instance_t p_instance,
                           NDIlib_tally_t *p_tally, uint32_t timeout_in_ms);

// MARK: - Finding (source discovery)

typedef void *NDIlib_find_instance_t;

typedef struct NDIlib_find_create_t {
    /// Include sources running on this machine.
    bool show_local_sources;
    /// Comma-separated groups to search (NULL = default group).
    const char *p_groups;
    /// Comma-separated extra IPs/subnets to query (NULL = none).
    const char *extra_ips;
} NDIlib_find_create_t;

/// A discovered NDI source. The NDI 5+ url address occupies the same ABI
/// slot as the NDI 4.x ip address, so this flat layout is ABI-correct.
typedef struct NDIlib_source_t {
    /// Display name, e.g. "MY-MAC (DualCast Studio Display)".
    const char *p_ndi_name;
    /// "ip:port" of the source (may be NULL for some discovery paths).
    const char *p_url_address;
} NDIlib_source_t;

NDIlib_find_instance_t NDIlib_find_create_v2(const NDIlib_find_create_t *p_create_settings);
void NDIlib_find_destroy(NDIlib_find_instance_t p_instance);

/// Array of currently known sources; valid until the next call on this
/// instance. Copy any strings you need to keep.
const NDIlib_source_t *NDIlib_find_get_current_sources(NDIlib_find_instance_t p_instance,
                                                       uint32_t *p_no_sources);

/// Blocks up to timeout_in_ms; returns true if the source list changed.
bool NDIlib_find_wait_for_sources(NDIlib_find_instance_t p_instance,
                                  uint32_t timeout_in_ms);

// MARK: - Receiving

typedef void *NDIlib_recv_instance_t;

typedef enum NDIlib_recv_bandwidth_e {
    NDIlib_recv_bandwidth_metadata_only = -10,
    NDIlib_recv_bandwidth_audio_only = 10,
    NDIlib_recv_bandwidth_lowest = 0,
    NDIlib_recv_bandwidth_highest = 100
} NDIlib_recv_bandwidth_e;

typedef enum NDIlib_recv_color_format_e {
    NDIlib_recv_color_format_BGRX_BGRA = 0,
    NDIlib_recv_color_format_UYVY_BGRA = 1,
    NDIlib_recv_color_format_RGBX_RGBA = 2,
    NDIlib_recv_color_format_UYVY_RGBA = 3,
    NDIlib_recv_color_format_fastest = 100,
    NDIlib_recv_color_format_best = 101
} NDIlib_recv_color_format_e;

typedef enum NDIlib_frame_type_e {
    NDIlib_frame_type_none = 0,
    NDIlib_frame_type_video = 1,
    NDIlib_frame_type_audio = 2,
    NDIlib_frame_type_metadata = 3,
    NDIlib_frame_type_error = 4,
    NDIlib_frame_type_status_change = 100
} NDIlib_frame_type_e;

typedef struct NDIlib_metadata_frame_t {
    int length;
    int64_t timecode;
    char *p_data;
} NDIlib_metadata_frame_t;

/// Audio frame descriptor (v3), 64 bytes. Layout verified against the
/// official SDK docs (sending-audio-frames example sets data_size_in_bytes
/// AND p_metadata as separate fields).
///
/// FLTP data layout (CRITICAL — getting this wrong means silent audio):
/// p_data points to ONE CONTIGUOUS planar float32 buffer holding all
/// channels back-to-back: [ch0 samples][ch1 samples]...
/// channel_stride_in_bytes = byte count of ONE channel = no_samples*4.
/// It is NOT a pointer-to-an-array-of-channel-pointers.
typedef struct NDIlib_audio_frame_v3_t {
    int sample_rate;
    int no_channels;
    int no_samples;
    int64_t timecode;
    int FourCC;
    uint8_t *p_data;
    union {
        int channel_stride_in_bytes;  // FLTP: bytes per channel
        int data_size_in_bytes;       // compressed audio (same ABI slot)
    };
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_audio_frame_v3_t;

typedef struct NDIlib_recv_create_v3_t {
    NDIlib_source_t source_to_connect_to;
    NDIlib_recv_color_format_e color_format;
    NDIlib_recv_bandwidth_e bandwidth;
    /// false = de-interlaced progressive frames (what we want).
    bool allow_video_fields;
    /// Name shown to the source for this connection (may be NULL).
    const char *p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

NDIlib_recv_instance_t NDIlib_recv_create_v3(const NDIlib_recv_create_v3_t *p_create_settings);
void NDIlib_recv_destroy(NDIlib_recv_instance_t p_instance);

/// Pull the next frame; blocks up to timeout_in_ms. Video/audio/metadata may
/// be NULL to skip that stream. Returned frames must be freed with the
/// matching NDIlib_recv_free_* call.
NDIlib_frame_type_e NDIlib_recv_capture_v3(NDIlib_recv_instance_t p_instance,
                                           NDIlib_video_frame_v2_t *p_video_data,
                                           NDIlib_audio_frame_v3_t *p_audio_data,
                                           NDIlib_metadata_frame_t *p_metadata,
                                           uint32_t timeout_in_ms);

void NDIlib_recv_free_video_v2(NDIlib_recv_instance_t p_instance,
                               const NDIlib_video_frame_v2_t *p_video_data);

/// Change receive bandwidth on the fly (e.g. lowest for inactive inputs).
bool NDIlib_recv_set_bandwidth(NDIlib_recv_instance_t p_instance,
                               NDIlib_recv_bandwidth_e bandwidth);

// MARK: - Audio

/// FourCC for planar 32-bit float audio (one pointer per channel).
#define NDILIB_FOURCC_AUDIO_FLTP NDILIB_FOURCC('F', 'L', 'T', 'P')

/// Submit an audio frame. NDI documents that audio and video may be sent
/// from separate threads without additional synchronisation.
void NDIlib_send_send_audio_v3(NDIlib_send_instance_t p_instance,
                               const NDIlib_audio_frame_v3_t *p_audio_data);

/// Free an audio frame obtained from NDIlib_recv_capture_v3.
void NDIlib_recv_free_audio_v3(NDIlib_recv_instance_t p_instance,
                               const NDIlib_audio_frame_v3_t *p_audio_data);

// MARK: - Convenience helpers

/// Submit one progressive BGRA frame with synthesized timecode.
/// Blocks until the frame has been consumed by the NDI encoder.
static inline void ndilib_send_video_bgra(NDIlib_send_instance_t sender,
                                          uint8_t *data,
                                          int width,
                                          int height,
                                          int stride,
                                          int fps_num,
                                          int fps_den) {
    NDIlib_video_frame_v2_t frame = {0};
    frame.xres = width;
    frame.yres = height;
    frame.FourCC = NDILIB_FOURCC('B', 'G', 'R', 'A');
    frame.frame_rate_N = fps_num;
    frame.frame_rate_D = fps_den;
    frame.picture_aspect_ratio = 0.0f; // 0 = square pixels from xres/yres
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDILIB_SEND_TIMECODE_SYNTHESIZE;
    frame.p_data = data;
    frame.line_stride_in_bytes = stride;
    NDIlib_send_send_video_v2(sender, &frame);
}

/// Zero-initialised heap allocation for use with NDIlib_recv_capture_v3,
/// so Swift never has to memberwise-initialise the union-bearing struct.
static inline NDIlib_video_frame_v2_t *ndilib_video_frame_alloc(void) {
    return (NDIlib_video_frame_v2_t *)calloc(1, sizeof(NDIlib_video_frame_v2_t));
}

static inline void ndilib_video_frame_free(NDIlib_video_frame_v2_t *f) {
    free(f);
}

/// Field readers that keep the anonymous union out of Swift's view.
static inline int ndilib_video_width(const NDIlib_video_frame_v2_t *f) { return f->xres; }
static inline int ndilib_video_height(const NDIlib_video_frame_v2_t *f) { return f->yres; }
static inline int ndilib_video_stride(const NDIlib_video_frame_v2_t *f) { return f->line_stride_in_bytes; }
static inline uint8_t *ndilib_video_data(const NDIlib_video_frame_v2_t *f) { return f->p_data; }

/// Zero-initialised heap allocation for use with NDIlib_recv_capture_v3.
static inline NDIlib_audio_frame_v3_t *ndilib_audio_frame_alloc(void) {
    return (NDIlib_audio_frame_v3_t *)calloc(1, sizeof(NDIlib_audio_frame_v3_t));
}

static inline void ndilib_audio_frame_free(NDIlib_audio_frame_v3_t *f) {
    free(f);
}

/// Submit one FLTP (planar float32) audio chunk with synthesised timecode.
/// planar_data is ONE contiguous buffer with all channels back-to-back
/// ([ch0][ch1]...); NDI locates channel N at planar_data + N * no_samples.
static inline void ndilib_send_audio_fltp(NDIlib_send_instance_t sender,
                                          const float *planar_data,
                                          int no_channels,
                                          int sample_rate,
                                          int no_samples) {
    NDIlib_audio_frame_v3_t frame = {0};
    frame.sample_rate = sample_rate;
    frame.no_channels = no_channels;
    frame.no_samples = no_samples;
    frame.timecode = NDILIB_SEND_TIMECODE_SYNTHESIZE;
    frame.FourCC = NDILIB_FOURCC_AUDIO_FLTP;
    frame.p_data = (uint8_t *)planar_data;
    frame.channel_stride_in_bytes = no_samples * (int)sizeof(float);
    NDIlib_send_send_audio_v3(sender, &frame);
}

#ifdef __cplusplus
}
#endif

#endif /* NDILIB_H */
