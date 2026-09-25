//
//  DualCastAudioRingBuffer.h
//  DualCastAudioDriver
//
//  Lock-free ring buffer in POSIX shared memory. The Switcher writes interleaved
//  Float32 PCM from the active NDI source; the AudioServerPlugIn driver reads it
//  in its real-time IO thread. A single device with stereo output is assumed.
//

#ifndef DualCastAudioRingBuffer_h
#define DualCastAudioRingBuffer_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DUALCAST_AUDIO_SHM_NAME    "/dualcast-audio-ring"
#define DUALCAST_AUDIO_CHANNELS    2
#define DUALCAST_AUDIO_SAMPLE_RATE 48000
#define DUALCAST_AUDIO_BUFFER_FRAMES 48000  // 1 second

typedef struct {
    // Written by producer (Switcher), read by consumer (driver).
    volatile uint32_t writeIndex;
    // Written by consumer, read by producer.
    volatile uint32_t readIndex;
    // Fixed at creation.
    uint32_t channels;
    uint32_t sampleRate;
    uint32_t capacityFrames;
    // Interleaved Float32 samples.
    float samples[DUALCAST_AUDIO_BUFFER_FRAMES * DUALCAST_AUDIO_CHANNELS];
} DualCastAudioRingBuffer;

/// Opens/creates the shared memory ring buffer. Returns NULL on failure.
DualCastAudioRingBuffer* DualCastAudioRingBufferOpen(bool create);

/// Closes the ring buffer. If `unlink` is true, destroys the shared memory.
void DualCastAudioRingBufferClose(DualCastAudioRingBuffer* buffer, bool unlink);

/// Returns the number of frames currently available to read.
uint32_t DualCastAudioRingBufferAvailableFrames(const DualCastAudioRingBuffer* buffer);

/// Returns the number of frames that can be written without wrapping.
uint32_t DualCastAudioRingBufferWritableFrames(const DualCastAudioRingBuffer* buffer);

/// Writes interleaved Float32 frames. Returns the number of frames written.
uint32_t DualCastAudioRingBufferWrite(DualCastAudioRingBuffer* buffer,
                                      const float* data,
                                      uint32_t frames);

/// Reads interleaved Float32 frames into `data`. Missing frames are filled with
/// silence. Returns the number of frames read (always `frames`).
uint32_t DualCastAudioRingBufferRead(DualCastAudioRingBuffer* buffer,
                                     float* data,
                                     uint32_t frames);

/// Clears the buffer.
void DualCastAudioRingBufferClear(DualCastAudioRingBuffer* buffer);

#ifdef __cplusplus
}
#endif

#endif /* DualCastAudioRingBuffer_h */
