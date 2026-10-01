#ifndef AMBER_FM_SYNTH_H
#define AMBER_FM_SYNTH_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct FMSynth FMSynth;
typedef enum FMParameter {
    FM_MASTER = 0,
    FM_CARRIER_RATIO, FM_MOD_RATIO, FM_MOD_INDEX,
    FM_AMP_ATTACK, FM_AMP_DECAY, FM_AMP_SUSTAIN, FM_AMP_RELEASE,
    FM_MOD_ATTACK, FM_MOD_DECAY, FM_MOD_SUSTAIN, FM_MOD_RELEASE,
    FM_VELOCITY,
    FM_DRIVE, FM_DRIVE_MIX,
    FM_CHORUS_RATE, FM_CHORUS_DEPTH, FM_CHORUS_MIX,
    FM_PHASER_RATE, FM_PHASER_DEPTH, FM_PHASER_MIX,
    FM_DELAY_TIME, FM_DELAY_FEEDBACK, FM_DELAY_MIX,
    FM_REVERB_SIZE, FM_REVERB_DAMP, FM_REVERB_MIX,
    FM_PARAMETER_COUNT
} FMParameter;

// Create/destroy only while no render or control calls are in flight.
// Fixed sample rate for each instance. Recreate on output format changes.
FMSynth *fm_create(double sample_rate);
void fm_destroy(FMSynth *synth);
// These control functions are safe from multiple producer threads.
void fm_set_parameter(FMSynth *synth, int parameter, float value);
float fm_get_parameter(const FMSynth *synth, int parameter);
void fm_note_on(FMSynth *synth, int channel, int note, int velocity);
void fm_note_off(FMSynth *synth, int channel, int note);
void fm_sustain(FMSynth *synth, int channel, int down);
void fm_pitch_bend(FMSynth *synth, int channel, float semitones);
void fm_all_notes_off(FMSynth *synth);
// MIDI CC123 releases keys while honoring sustain; CC120 silences this channel.
void fm_channel_all_notes_off(FMSynth *synth, int channel, int immediate);
// Single consumer. No allocation, blocking locks, logging, or I/O during render.
void fm_render(FMSynth *synth, float *left, float *right, uint32_t frames);
// Bounded, lock-free telemetry read from UI. Waveform samples are [-1, 1].
int fm_active_voices(const FMSynth *synth);
float fm_peak_level(const FMSynth *synth);
uint32_t fm_dropped_events(const FMSynth *synth);
uint32_t fm_copy_waveform(const FMSynth *synth, float *output, uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
