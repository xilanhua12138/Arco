#ifndef ARCO_AUDIO_RT_H
#define ARCO_AUDIO_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

typedef struct ArcoAudioRtProducer ArcoAudioRtProducer;
typedef struct ArcoAudioRtConsumer ArcoAudioRtConsumer;

enum {
    ARCO_AUDIO_RT_OK = 0,
    ARCO_AUDIO_RT_INVALID_ARGUMENT = 1,
    ARCO_AUDIO_RT_UNSUPPORTED_FORMAT = 2,
    ARCO_AUDIO_RT_INTERNAL_ERROR = 3,
    ARCO_AUDIO_RT_PANIC = 4,
    ARCO_AUDIO_RT_FINISHED = 5
};

typedef struct ArcoAudioRtPushResult {
    int32_t status;
    uint32_t accepted_frames;
    uint32_t dropped_frames;
    uint64_t overflow_epoch;
} ArcoAudioRtPushResult;

typedef struct ArcoAudioRtDrainResult {
    int32_t status;
    uint32_t frame_count;
    uint64_t dropped_input_frames;
    uint8_t discontinuity;
    uint8_t finished;
    uint8_t reserved[6];
} ArcoAudioRtDrainResult;

int32_t arco_audio_rt_source_create(
    const AudioStreamBasicDescription * _Nonnull format,
    double target_rate,
    uint32_t capacity_frames,
    ArcoAudioRtProducer * _Nullable * _Nonnull out_producer,
    ArcoAudioRtConsumer * _Nullable * _Nonnull out_consumer
);

ArcoAudioRtPushResult arco_audio_rt_push_planar_f32(
    ArcoAudioRtProducer *producer,
    const float * _Nonnull const * _Nonnull channels,
    uint32_t channel_count,
    uint32_t frame_count
);

ArcoAudioRtPushResult arco_audio_rt_push_audio_buffer_list(
    ArcoAudioRtProducer *producer,
    const AudioBufferList *input
);

ArcoAudioRtDrainResult arco_audio_rt_consumer_drain_i16(
    ArcoAudioRtConsumer *consumer,
    int16_t *output,
    uint32_t capacity_frames
);

/*
 * Lifetime contract: unregister/stop the Core Audio IOProc or AVAudioEngine
 * tap, wait until every in-flight push has returned, and stop the consumer
 * drain queue before calling finish or either destroy function. A producer
 * handle must never be pushed, finished, or destroyed concurrently.
 */
int32_t arco_audio_rt_producer_finish(ArcoAudioRtProducer *producer);
void arco_audio_rt_producer_destroy(ArcoAudioRtProducer *producer);
void arco_audio_rt_consumer_destroy(ArcoAudioRtConsumer *consumer);

OSStatus arco_audio_rt_io_proc(
    AudioObjectID in_device,
    const AudioTimeStamp * _Nonnull in_now,
    const AudioBufferList * _Nonnull in_input_data,
    const AudioTimeStamp * _Nonnull in_input_time,
    AudioBufferList * _Nonnull out_output_data,
    const AudioTimeStamp * _Nonnull in_output_time,
    void * _Nullable in_client_data
) CA_REALTIME_API;

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
