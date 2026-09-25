//
//  DualCastAudioRingBuffer.c
//  DualCastAudioDriver
//
//  POSIX shared memory ring buffer for Float32 interleaved PCM.
//

#include "DualCastAudioRingBuffer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const size_t kBufferSize = sizeof(DualCastAudioRingBuffer);

DualCastAudioRingBuffer* DualCastAudioRingBufferOpen(bool create) {
    int flags = O_RDWR;
    if (create) {
        flags |= O_CREAT | O_EXCL;
    }

    int fd = shm_open(DUALCAST_AUDIO_SHM_NAME, flags, 0666);
    if (fd < 0) {
        // If creating failed because it exists, try opening existing.
        if (create && errno == EEXIST) {
            fd = shm_open(DUALCAST_AUDIO_SHM_NAME, O_RDWR, 0666);
        }
        if (fd < 0) {
            perror("DualCastAudioRingBufferOpen: shm_open");
            return NULL;
        }
        create = false;
    }

    if (create) {
        if (ftruncate(fd, (off_t)kBufferSize) != 0) {
            perror("DualCastAudioRingBufferOpen: ftruncate");
            close(fd);
            shm_unlink(DUALCAST_AUDIO_SHM_NAME);
            return NULL;
        }
    }

    void* memory = mmap(NULL, kBufferSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (memory == MAP_FAILED) {
        perror("DualCastAudioRingBufferOpen: mmap");
        return NULL;
    }

    DualCastAudioRingBuffer* buffer = (DualCastAudioRingBuffer*)memory;
    if (create) {
        buffer->writeIndex = 0;
        buffer->readIndex = 0;
        buffer->channels = DUALCAST_AUDIO_CHANNELS;
        buffer->sampleRate = DUALCAST_AUDIO_SAMPLE_RATE;
        buffer->capacityFrames = DUALCAST_AUDIO_BUFFER_FRAMES;
        memset(buffer->samples, 0, sizeof(buffer->samples));
    }
    return buffer;
}

void DualCastAudioRingBufferClose(DualCastAudioRingBuffer* buffer, bool unlink) {
    if (!buffer) return;
    munmap(buffer, kBufferSize);
    if (unlink) {
        shm_unlink(DUALCAST_AUDIO_SHM_NAME);
    }
}

uint32_t DualCastAudioRingBufferAvailableFrames(const DualCastAudioRingBuffer* buffer) {
    uint32_t writeIndex = buffer->writeIndex;
    uint32_t readIndex = buffer->readIndex;
    if (writeIndex >= readIndex) {
        return writeIndex - readIndex;
    }
    return buffer->capacityFrames - readIndex + writeIndex;
}

uint32_t DualCastAudioRingBufferWritableFrames(const DualCastAudioRingBuffer* buffer) {
    return buffer->capacityFrames - DualCastAudioRingBufferAvailableFrames(buffer) - 1;
}

uint32_t DualCastAudioRingBufferWrite(DualCastAudioRingBuffer* buffer,
                                      const float* data,
                                      uint32_t frames) {
    uint32_t writable = DualCastAudioRingBufferWritableFrames(buffer);
    uint32_t toWrite = (frames < writable) ? frames : writable;
    uint32_t channels = buffer->channels;
    uint32_t capacity = buffer->capacityFrames;
    uint32_t writeIndex = buffer->writeIndex;

    for (uint32_t i = 0; i < toWrite; ++i) {
        uint32_t frameIndex = (writeIndex + i) % capacity;
        for (uint32_t ch = 0; ch < channels; ++ch) {
            buffer->samples[frameIndex * channels + ch] = data[i * channels + ch];
        }
    }

    buffer->writeIndex = (writeIndex + toWrite) % capacity;
    return toWrite;
}

uint32_t DualCastAudioRingBufferRead(DualCastAudioRingBuffer* buffer,
                                     float* data,
                                     uint32_t frames) {
    uint32_t available = DualCastAudioRingBufferAvailableFrames(buffer);
    uint32_t toRead = (frames < available) ? frames : available;
    uint32_t channels = buffer->channels;
    uint32_t capacity = buffer->capacityFrames;
    uint32_t readIndex = buffer->readIndex;

    for (uint32_t i = 0; i < toRead; ++i) {
        uint32_t frameIndex = (readIndex + i) % capacity;
        for (uint32_t ch = 0; ch < channels; ++ch) {
            data[i * channels + ch] = buffer->samples[frameIndex * channels + ch];
        }
    }

    // Silence for underrun.
    for (uint32_t i = toRead; i < frames; ++i) {
        for (uint32_t ch = 0; ch < channels; ++ch) {
            data[i * channels + ch] = 0.0f;
        }
    }

    buffer->readIndex = (readIndex + toRead) % capacity;
    return frames;
}

void DualCastAudioRingBufferClear(DualCastAudioRingBuffer* buffer) {
    buffer->readIndex = 0;
    buffer->writeIndex = 0;
    memset(buffer->samples, 0, sizeof(buffer->samples));
}
