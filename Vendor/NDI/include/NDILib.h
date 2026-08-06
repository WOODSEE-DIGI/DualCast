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

/// Video frame descriptor (v2). Layout must match the official SDK exactly.
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
        int line_stride_in_bytes;
        const char *p_metadata;
    };
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

#ifdef __cplusplus
}
#endif

#endif /* NDILIB_H */
