//
//  DualCastAudioDriver.c
//  DualCastAudioDriver
//
//  Minimal AudioServerPlugIn driver exposing one stereo output device
//  "DualCast Audio" that reads Float32 PCM from a POSIX shared memory ring
//  buffer populated by the DualCast Switcher.
//

#include "DualCastAudioRingBuffer.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#pragma mark - Object IDs

enum {
    kObjectIDPlugIn     = 1,
    kObjectIDDevice     = 2,
    kObjectIDStreamOut  = 3
};

#pragma mark - State

typedef struct {
    AudioServerPlugInHostRef host;
    DualCastAudioRingBuffer* ringBuffer;
    UInt64                   ioCounter;
    UInt64                   seed;
    pthread_mutex_t          mutex;
    Float64                  sampleRate;
    UInt32                   ioBufferFrameSize;
    bool                     ioRunning;
} DualCastDriverState;

static DualCastDriverState gState = {
    .host = NULL,
    .ringBuffer = NULL,
    .ioCounter = 0,
    .seed = 1,
    .sampleRate = DUALCAST_AUDIO_SAMPLE_RATE,
    .ioBufferFrameSize = 512,
    .ioRunning = false
};

#pragma mark - Helpers

static UInt64 GetHostTime(void) {
    return mach_absolute_time();
}

static void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[DualCastAudioDriver] ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

#pragma mark - CFPlugIn Lifecycle

static ULONG gRefCount = 1;

static HRESULT STDMETHODCALLTYPE DualCast_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef driverUUID = kAudioServerPlugInDriverInterfaceUUID;
    if (CFEqual(uuid, driverUUID)) {
        gRefCount++;
        *outInterface = inDriver;
        CFRelease(uuid);
        return S_OK;
    }
    CFRelease(uuid);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE DualCast_AddRef(void* inDriver) {
    (void)inDriver;
    return ++gRefCount;
}

static ULONG STDMETHODCALLTYPE DualCast_Release(void* inDriver) {
    (void)inDriver;
    ULONG result = --gRefCount;
    if (result == 0) {
        // Never truly destroy; host keeps us alive.
    }
    return result;
}

#pragma mark - Driver Interface

static OSStatus DualCast_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    pthread_mutex_init(&gState.mutex, NULL);
    gState.host = inHost;
    gState.ringBuffer = DualCastAudioRingBufferOpen(false);
    Log("initialized, ring buffer %p", (void*)gState.ringBuffer);
    return kAudioHardwareNoError;
}

static OSStatus DualCast_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                      const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo;
    *outDeviceObjectID = kObjectIDDevice;
    return kAudioHardwareNoError;
}

static OSStatus DualCast_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareNoError;
}

static OSStatus DualCast_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus DualCast_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                             const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus DualCast_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                           UInt64 inChangeAction, void* inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus DualCast_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                         UInt64 inChangeAction, void* inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Properties

static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                            const AudioObjectPropertyAddress* inAddress) {
    (void)inDriver; (void)inClientProcessID;

    Boolean result = false;
    switch (inObjectID) {
        case kObjectIDPlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyDeviceList:
                    result = true;
                    break;
            }
            break;
        case kObjectIDDevice:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertyStreamConfiguration:
                case kAudioDevicePropertyIcon:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    result = true;
                    break;
            }
            break;
        case kObjectIDStreamOut:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                    result = true;
                    break;
            }
            break;
    }
    return result;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inDriver; (void)inClientProcessID;

    switch (inObjectID) {
        case kObjectIDStreamOut:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyVirtualFormat:
                    *outIsSettable = true;
                    return kAudioHardwareNoError;
            }
            break;
    }
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                     const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                     const void* inQualifierData, UInt32* outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    switch (inObjectID) {
        case kObjectIDPlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyManufacturer:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
        case kObjectIDDevice:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyStreams:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyStreamConfiguration:
                    *outDataSize = sizeof(AudioBufferList) + sizeof(AudioBuffer);
                    break;
                case kAudioDevicePropertyIcon:
                    *outDataSize = sizeof(CFURLRef);
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = sizeof(AudioValueRange);
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
        case kObjectIDStreamOut:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                 const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    OSStatus status = kAudioHardwareNoError;
    UInt32 dataSize = 0;

    switch (inObjectID) {
        case kObjectIDPlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyManufacturer:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("woodsee");
                    break;
                case kAudioPlugInPropertyDeviceList:
                    dataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectIDDevice;
                    break;
                default:
                    status = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectIDDevice:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.apple.audio.CoreAudioDevice");
                    break;
                case kAudioObjectPropertyClass:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.apple.audio.CoreAudioDevice");
                    break;
                case kAudioObjectPropertyOwner:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("DualCast Audio");
                    break;
                case kAudioObjectPropertyName:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("DualCast Audio");
                    break;
                case kAudioObjectPropertyManufacturer:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("woodsee");
                    break;
                case kAudioObjectPropertyOwnedObjects:
                    dataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectIDStreamOut;
                    break;
                case kAudioDevicePropertyDeviceUID:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.woodseedigi.DualCastAudioDevice");
                    break;
                case kAudioDevicePropertyModelUID:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.woodseedigi.DualCastAudioDevice");
                    break;
                case kAudioDevicePropertyTransportType:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
                    break;
                case kAudioDevicePropertyRelatedDevices:
                    dataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectIDDevice;
                    break;
                case kAudioDevicePropertyClockDomain:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    break;
                case kAudioDevicePropertyDeviceIsAlive:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    break;
                case kAudioDevicePropertyDeviceIsRunning:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = gState.ioRunning ? 1 : 0;
                    break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    break;
                case kAudioDevicePropertyLatency:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    break;
                case kAudioDevicePropertyStreams:
                    dataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kObjectIDStreamOut;
                    break;
                case kAudioDevicePropertyStreamConfiguration: {
                    dataSize = sizeof(AudioBufferList) + sizeof(AudioBuffer);
                    AudioBufferList* list = (AudioBufferList*)outData;
                    list->mNumberBuffers = 1;
                    list->mBuffers[0].mNumberChannels = DUALCAST_AUDIO_CHANNELS;
                    list->mBuffers[0].mDataByteSize = 0;
                    list->mBuffers[0].mData = NULL;
                    break;
                }
                case kAudioDevicePropertyIcon:
                    dataSize = sizeof(CFURLRef);
                    *(CFURLRef*)outData = NULL;
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    dataSize = sizeof(Float64);
                    *(Float64*)outData = gState.sampleRate;
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    dataSize = sizeof(AudioValueRange);
                    ((AudioValueRange*)outData)->mMinimum = gState.sampleRate;
                    ((AudioValueRange*)outData)->mMaximum = gState.sampleRate;
                    break;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = gState.ioBufferFrameSize;
                    break;
                default:
                    status = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectIDStreamOut:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.apple.audio.CoreAudioStream");
                    break;
                case kAudioObjectPropertyClass:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("com.apple.audio.CoreAudioStream");
                    break;
                case kAudioObjectPropertyOwner:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("DualCast Audio");
                    break;
                case kAudioObjectPropertyName:
                    dataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFSTR("DualCast Audio Output");
                    break;
                case kAudioStreamPropertyIsActive:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    break;
                case kAudioStreamPropertyDirection:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0; // output
                    break;
                case kAudioStreamPropertyTerminalType:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = kAudioStreamTerminalTypeSpeaker;
                    break;
                case kAudioStreamPropertyStartingChannel:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    break;
                case kAudioStreamPropertyLatency:
                    dataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    break;
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyAvailableVirtualFormats: {
                    dataSize = sizeof(AudioStreamBasicDescription);
                    AudioStreamBasicDescription* desc = (AudioStreamBasicDescription*)outData;
                    desc->mSampleRate = gState.sampleRate;
                    desc->mFormatID = kAudioFormatLinearPCM;
                    desc->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    desc->mBytesPerPacket = DUALCAST_AUDIO_CHANNELS * sizeof(Float32);
                    desc->mFramesPerPacket = 1;
                    desc->mBytesPerFrame = DUALCAST_AUDIO_CHANNELS * sizeof(Float32);
                    desc->mChannelsPerFrame = DUALCAST_AUDIO_CHANNELS;
                    desc->mBitsPerChannel = 32;
                    desc->mReserved = 0;
                    break;
                }
                default:
                    status = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        default:
            status = kAudioHardwareBadObjectError;
            break;
    }

    if (status == kAudioHardwareNoError) {
        *outDataSize = dataSize;
    }
    return status;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                 const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    gState.ioRunning = true;
    gState.ioCounter = 0;
    gState.seed++;
    if (!gState.ringBuffer) {
        gState.ringBuffer = DualCastAudioRingBufferOpen(false);
    }
    if (gState.ringBuffer) {
        DualCastAudioRingBufferClear(gState.ringBuffer);
    }
    pthread_mutex_unlock(&gState.mutex);
    Log("IO started");
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    gState.ioRunning = false;
    pthread_mutex_unlock(&gState.mutex);
    Log("IO stopped");
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    *outSampleTime = (Float64)gState.ioCounter;
    *outHostTime = GetHostTime();
    *outSeed = gState.seed;
    pthread_mutex_unlock(&gState.mutex);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                               AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                               UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                               void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID;
    (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        pthread_mutex_lock(&gState.mutex);
        gState.ioBufferFrameSize = inIOBufferFrameSize;
        if (gState.ringBuffer) {
            DualCastAudioRingBufferRead(gState.ringBuffer, (float*)ioMainBuffer, inIOBufferFrameSize);
        } else {
            memset(ioMainBuffer, 0, inIOBufferFrameSize * DUALCAST_AUDIO_CHANNELS * sizeof(float));
        }
        gState.ioCounter += inIOBufferFrameSize;
        pthread_mutex_unlock(&gState.mutex);
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Interface Table

static AudioServerPlugInDriverInterface gDualCastDriverInterface = {
    NULL,
    DualCast_QueryInterface,
    DualCast_AddRef,
    DualCast_Release,
    DualCast_Initialize,
    DualCast_CreateDevice,
    DualCast_DestroyDevice,
    DualCast_AddDeviceClient,
    DualCast_RemoveDeviceClient,
    DualCast_PerformDeviceConfigurationChange,
    DualCast_AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation
};

#pragma mark - Factory

static AudioServerPlugInDriverInterface* gDualCastDriverInterfacePtr = &gDualCastDriverInterface;

void* AudioServerPlugInFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        gRefCount++;
        return &gDualCastDriverInterfacePtr;
    }
    return NULL;
}
