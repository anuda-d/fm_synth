#include "FMSynth.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// This catches C++ allocations on the rendering thread, including aligned new.
// It does not claim to intercept direct malloc calls or platform allocations.
static thread_local bool countRenderAllocations = false;
static thread_local size_t renderAllocations = 0;

static void *allocate(size_t bytes, size_t alignment = 0) {
    if (countRenderAllocations) ++renderAllocations;
    void *result = nullptr;
    if (alignment) {
        if (posix_memalign(&result, alignment, std::max(size_t(1), bytes)) != 0)
            result = nullptr;
    } else {
        result = std::malloc(std::max(size_t(1), bytes));
    }
    if (!result) throw std::bad_alloc();
    return result;
}

void *operator new(size_t n) { return allocate(n); }
void *operator new[](size_t n) { return allocate(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, size_t) noexcept { std::free(p); }
void operator delete[](void *p, size_t) noexcept { std::free(p); }
void *operator new(size_t n, std::align_val_t a) { return allocate(n, size_t(a)); }
void *operator new[](size_t n, std::align_val_t a) { return allocate(n, size_t(a)); }
void operator delete(void *p, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void *p, std::align_val_t) noexcept { std::free(p); }
void operator delete(void *p, size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void *p, size_t, std::align_val_t) noexcept { std::free(p); }
void *operator new(size_t n, const std::nothrow_t &) noexcept {
    try { return allocate(n); } catch (...) { return nullptr; }
}
void *operator new[](size_t n, const std::nothrow_t &) noexcept {
    try { return allocate(n); } catch (...) { return nullptr; }
}
void operator delete(void *p, const std::nothrow_t &) noexcept { std::free(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { std::free(p); }

namespace {
constexpr double pi = 3.14159265358979323846;
using Synth = std::unique_ptr<FMSynth, decltype(&fm_destroy)>;

struct Audio {
    std::vector<float> left;
    std::vector<float> right;
};

void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

void near(double actual, double expected, double tolerance, const std::string &label) {
    require(std::isfinite(actual) && std::abs(actual - expected) <= tolerance,
            label + ": got " + std::to_string(actual) + ", expected " +
                std::to_string(expected) + " +/- " + std::to_string(tolerance));
}

void renderChecked(FMSynth *synth, float *left, float *right, uint32_t frames) {
    const size_t before = renderAllocations;
    countRenderAllocations = true;
    fm_render(synth, left, right, frames);
    countRenderAllocations = false;
    require(renderAllocations == before, "render performed a C++ heap allocation");
}

Audio render(FMSynth *synth, double sampleRate, double seconds, uint32_t block = 128) {
    const auto frames = size_t(std::llround(sampleRate * seconds));
    Audio result{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t offset = 0; offset < frames; offset += block) {
        const auto count = uint32_t(std::min(size_t(block), frames - offset));
        renderChecked(synth, result.left.data() + offset, result.right.data() + offset, count);
    }
    return result;
}

double rms(const std::vector<float> &samples, size_t begin = 0, size_t end = 0) {
    if (!end) end = samples.size();
    require(begin < end && end <= samples.size(), "invalid measurement window");
    double power = 0;
    for (size_t i = begin; i < end; ++i) power += double(samples[i]) * samples[i];
    return std::sqrt(power / double(end - begin));
}

double windowRMS(const std::vector<float> &samples, double rate, double start, double end) {
    return rms(samples, size_t(start * rate), size_t(end * rate));
}

double peak(const Audio &audio) {
    double value = 0;
    for (const auto *channel : {&audio.left, &audio.right}) {
        for (float sample : *channel) {
            require(std::isfinite(sample), "nonfinite sample reached audio output");
            value = std::max(value, std::abs(double(sample)));
        }
    }
    return value;
}

// A Hann-windowed single-frequency projection is independent of oscillator phase.
// Windows span many cycles, so unrelated frequencies do not masquerade as energy.
double magnitude(const std::vector<float> &samples, double rate, double frequency,
                 size_t begin = 0, size_t end = 0) {
    if (!end) end = samples.size();
    const auto length = end - begin;
    require(length >= 8, "spectral window too short");
    double re = 0, im = 0, weightSum = 0;
    for (size_t i = 0; i < length; ++i) {
        const double weight = 0.5 - 0.5 * std::cos(2 * pi * double(i) / double(length - 1));
        const double phase = 2 * pi * frequency * double(i) / rate;
        re += samples[begin + i] * weight * std::cos(phase);
        im -= samples[begin + i] * weight * std::sin(phase);
        weightSum += weight;
    }
    return 2 * std::hypot(re, im) / weightSum;
}

double frequencyFromCrossings(const std::vector<float> &samples, double rate) {
    std::vector<double> crossings;
    for (size_t i = 1; i < samples.size(); ++i) {
        if (samples[i - 1] <= 0 && samples[i] > 0) {
            const double fraction = -double(samples[i - 1]) /
                                    (double(samples[i]) - samples[i - 1]);
            crossings.push_back(double(i - 1) + fraction);
        }
    }
    require(crossings.size() > 10, "too few zero crossings to measure pitch");
    return rate * double(crossings.size() - 1) / (crossings.back() - crossings.front());
}

double difference(const Audio &a, const Audio &b) {
    require(a.left.size() == b.left.size(), "different comparison lengths");
    double power = 0;
    for (size_t i = 0; i < a.left.size(); ++i) {
        const double l = a.left[i] - b.left[i];
        const double r = a.right[i] - b.right[i];
        power += l * l + r * r;
    }
    return std::sqrt(power / (2 * a.left.size()));
}

void dryParameters(FMSynth *synth) {
    fm_set_parameter(synth, FM_MASTER, .25f);
    fm_set_parameter(synth, FM_CARRIER_RATIO, 1);
    fm_set_parameter(synth, FM_MOD_RATIO, std::sqrt(2.0f));
    fm_set_parameter(synth, FM_MOD_INDEX, 0);
    fm_set_parameter(synth, FM_AMP_ATTACK, .001f);
    fm_set_parameter(synth, FM_AMP_DECAY, .005f);
    fm_set_parameter(synth, FM_AMP_SUSTAIN, 1);
    fm_set_parameter(synth, FM_AMP_RELEASE, .05f);
    fm_set_parameter(synth, FM_MOD_ATTACK, .001f);
    fm_set_parameter(synth, FM_MOD_DECAY, .005f);
    fm_set_parameter(synth, FM_MOD_SUSTAIN, 1);
    fm_set_parameter(synth, FM_MOD_RELEASE, .05f);
    fm_set_parameter(synth, FM_VELOCITY, 0);
    for (auto mix : {FM_DRIVE_MIX, FM_CHORUS_MIX, FM_PHASER_MIX,
                     FM_DELAY_MIX, FM_REVERB_MIX}) fm_set_parameter(synth, mix, 0);
}

Synth makeSynth(double rate = 48000) {
    Synth synth(fm_create(rate), fm_destroy);
    require(bool(synth), "fm_create failed");
    dryParameters(synth.get());
    // Parameter ramping and delay initialization settle before test gestures.
    render(synth.get(), rate, .2);
    return synth;
}

void silenceAndSine() {
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        auto synth = makeSynth(rate);
        require(peak(render(synth.get(), rate, .2)) < 1e-8, "idle synth is not silent");
        fm_note_on(synth.get(), 0, 69, 100);
        render(synth.get(), rate, .2);
        const auto audio = render(synth.get(), rate, .5);
        near(frequencyFromCrossings(audio.left, rate), 440, .02, "A4 pitch");
        const double fundamental = magnitude(audio.left, rate, 440);
        require(fundamental > .001 && fundamental < .8, "sine level outside useful range");
        near(rms(audio.left), fundamental / std::sqrt(2.0), fundamental * .015,
             "sine RMS versus fundamental amplitude");
        require(magnitude(audio.left, rate, 1320) < fundamental * .015,
                "zero-index oscillator has excessive harmonic distortion");
        fm_set_parameter(synth.get(), FM_MASTER, .125f);
        render(synth.get(), rate, .2);
        const double quieter = magnitude(render(synth.get(), rate, .5).left, rate, 440);
        near(quieter / fundamental, .5, .025, "master amplitude scaling");
        fm_note_off(synth.get(), 0, 69);
        render(synth.get(), rate, .2);
        require(peak(render(synth.get(), rate, .1)) < 1e-7, "released sine did not reach silence");
        require(fm_active_voices(synth.get()) == 0, "released voice remains active");
    }
}

void fmSidebands() {
    // For sin(wc*t + sin(wm*t)), Bessel J0(1)=.7651977 and J1(1)=.4400506.
    // An irrational ratio keeps reflected lower sidebands from coinciding.
    constexpr double expected = .4400505857449335 / .7651976865579666;
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        auto synth = makeSynth(rate);
        fm_set_parameter(synth.get(), FM_MASTER, .1f);
        fm_set_parameter(synth.get(), FM_MOD_INDEX, 1);
        fm_note_on(synth.get(), 0, 69, 100);
        render(synth.get(), rate, 1);
        auto audio = render(synth.get(), rate, 1);
        const double carrier = magnitude(audio.left, rate, 440);
        const double upper = magnitude(audio.left, rate, 440 * (1 + std::sqrt(2.0)));
        const double lower = magnitude(audio.left, rate, 440 * (std::sqrt(2.0) - 1));
        near(upper / carrier, expected, .04, "FM first upper sideband/carrier");
        near(lower / carrier, expected, .04, "FM first lower sideband/carrier");
        const double second = magnitude(audio.left, rate, 440 * (1 + 2 * std::sqrt(2.0)));
        near(second / carrier, .1149034849319005 / .7651976865579666, .025,
             "FM second upper sideband/carrier");
    }
}

void envelopesAndVelocity() {
    constexpr double rate = 48000;
    auto synth = makeSynth(rate);
    fm_set_parameter(synth.get(), FM_AMP_ATTACK, .25f);
    fm_set_parameter(synth.get(), FM_AMP_RELEASE, .25f);
    render(synth.get(), rate, .2);
    fm_note_on(synth.get(), 0, 69, 100);
    auto attack = render(synth.get(), rate, .4);
    require(windowRMS(attack.left, rate, .20, .24) >
                3 * windowRMS(attack.left, rate, .02, .06),
            "amplitude attack did not rise over requested interval");
    fm_note_off(synth.get(), 0, 69);
    auto release = render(synth.get(), rate, .5);
    require(windowRMS(release.left, rate, .01, .04) >
                4 * windowRMS(release.left, rate, .18, .22),
            "amplitude release did not decay");
    require(windowRMS(release.left, rate, .35, .49) < 1e-7, "release never reached silence");

    // A modulation attack must change timbre independently of the amplitude attack.
    auto mod = makeSynth(rate);
    fm_set_parameter(mod.get(), FM_MOD_INDEX, 1);
    fm_set_parameter(mod.get(), FM_MOD_ATTACK, .3f);
    render(mod.get(), rate, .2);
    fm_note_on(mod.get(), 0, 69, 100);
    const auto modAttack = render(mod.get(), rate, .65);
    const double sideband = 440 * (1 + std::sqrt(2.0));
    const auto ratioIn = [&](double start, double end) {
        const size_t a = size_t(start * rate), b = size_t(end * rate);
        return magnitude(modAttack.left, rate, sideband, a, b) /
               magnitude(modAttack.left, rate, 440, a, b);
    };
    require(ratioIn(.4, .6) > 3 * ratioIn(.02, .07), "modulation attack did not evolve timbre");
    require(windowRMS(modAttack.left, rate, .02, .07) > .5 *
                windowRMS(modAttack.left, rate, .4, .6),
            "modulation attack incorrectly suppressed amplitude");
    fm_set_parameter(mod.get(), FM_AMP_RELEASE, 1);
    fm_set_parameter(mod.get(), FM_MOD_RELEASE, .05f);
    render(mod.get(), rate, .2);
    fm_note_off(mod.get(), 0, 69);
    const auto modRelease = render(mod.get(), rate, .3);
    const size_t releaseBegin = size_t(.12 * rate), releaseEnd = size_t(.22 * rate);
    const double releaseCarrier = magnitude(modRelease.left, rate, 440, releaseBegin, releaseEnd);
    require(releaseCarrier > .001, "amplitude release ended before independent modulation release");
    require(magnitude(modRelease.left, rate, sideband, releaseBegin, releaseEnd) <
                releaseCarrier * .02,
            "modulation release did not independently return to a sine wave");
    render(mod.get(), rate, 1);
    require(peak(render(mod.get(), rate, .1)) < 1e-7, "independent envelope release left a sounding voice");

    const auto levelAt = [&](int velocity, float sensitivity) {
        auto voice = makeSynth(rate);
        fm_set_parameter(voice.get(), FM_VELOCITY, sensitivity);
        render(voice.get(), rate, .15);
        fm_note_on(voice.get(), 0, 69, velocity);
        render(voice.get(), rate, .15);
        return rms(render(voice.get(), rate, .15).left);
    };
    require(levelAt(110, 1) > 1.7 * levelAt(40, 1), "velocity sensitivity has too little response");
    near(levelAt(110, 0) / levelAt(40, 0), 1, .01, "disabled velocity sensitivity");
}

void midiAndPolyphony() {
    constexpr double rate = 48000;
    auto synth = makeSynth(rate);
    for (int note : {60, 64, 67}) fm_note_on(synth.get(), 0, note, 90);
    render(synth.get(), rate, .2);
    auto chord = render(synth.get(), rate, .5);
    for (int note : {60, 64, 67}) {
        const double frequency = 440 * std::pow(2.0, (note - 69) / 12.0);
        require(magnitude(chord.left, rate, frequency) > .001, "missing chord frequency");
    }
    require(fm_active_voices(synth.get()) >= 3, "chord did not allocate separate voices");
    fm_all_notes_off(synth.get());
    render(synth.get(), rate, .1);
    require(peak(render(synth.get(), rate, .1)) < 1e-7, "panic left a sounding chord");

    fm_note_on(synth.get(), 0, 69, 100);
    fm_note_on(synth.get(), 1, 72, 100);
    fm_sustain(synth.get(), 0, 1);
    render(synth.get(), rate, .1);
    fm_note_off(synth.get(), 0, 69);
    fm_note_off(synth.get(), 1, 72);
    render(synth.get(), rate, .2);
    auto held = render(synth.get(), rate, .5);
    require(magnitude(held.left, rate, 440) > .001, "sustain failed to hold its channel");
    require(magnitude(held.left, rate, 523.2511306) < .00001,
            "sustain leaked into another MIDI channel");
    fm_sustain(synth.get(), 0, 0);
    render(synth.get(), rate, .2);
    require(peak(render(synth.get(), rate, .1)) < 1e-7, "pedal up left a stuck note");

    fm_note_on(synth.get(), 0, 69, 100);
    fm_note_on(synth.get(), 1, 72, 100);
    fm_pitch_bend(synth.get(), 0, 2);
    render(synth.get(), rate, .3);
    auto bent = render(synth.get(), rate, .5);
    require(magnitude(bent.left, rate, 493.8833013) > .001, "pitch bend missed the target pitch");
    require(magnitude(bent.left, rate, 523.2511306) > .001, "pitch bend affected the other channel");
    require(magnitude(bent.left, rate, 440) < .00001, "pitch bend retained original pitch");
    fm_note_on(synth.get(), 0, 69, 0);
    fm_note_on(synth.get(), 1, 72, 0);
    render(synth.get(), rate, .3);
    require(peak(render(synth.get(), rate, .1)) < 1e-7, "zero-velocity note-on failed to release");
}

void repeatedNotesStealingAndOverflow() {
    constexpr double rate = 48000;
    auto synth = makeSynth(rate);
    for (int i = 0; i < 80; ++i) {
        fm_note_on(synth.get(), 0, 60, 100);
        require(peak(render(synth.get(), rate, .002)) <= 1.001, "retrigger output unbounded");
    }
    fm_note_off(synth.get(), 0, 60);
    render(synth.get(), rate, .2);
    require(fm_active_voices(synth.get()) == 0, "repeated note left stuck voices");

    for (int i = 0; i < 80; ++i) {
        fm_note_on(synth.get(), i % 16, 24 + i, 110);
        render(synth.get(), rate, .002);
    }
    require(fm_active_voices(synth.get()) <= 32, "voice stealing exceeded bounded voice capacity");
    require(peak(render(synth.get(), rate, .2)) <= 1.001, "voice-stealing output unbounded");
    for (int i = 0; i < 80; ++i) fm_note_off(synth.get(), i % 16, 24 + i);
    render(synth.get(), rate, .2);
    require(fm_active_voices(synth.get()) == 0, "stolen voices failed to release");

    fm_note_on(synth.get(), 0, 69, 100);
    render(synth.get(), rate, .1);
    const uint32_t droppedBefore = fm_dropped_events(synth.get());
    // Fill the event queue with control traffic, then risk dropping the only release.
    for (int i = 0; i < 5000; ++i) fm_pitch_bend(synth.get(), i % 16, float(i % 3));
    fm_note_off(synth.get(), 0, 69);
    render(synth.get(), rate, .3);
    require(fm_dropped_events(synth.get()) > droppedBefore, "overflow scenario did not fill event queue");
    require(fm_active_voices(synth.get()) == 0, "queue overflow left a stuck note");
    require(peak(render(synth.get(), rate, .1)) < 1e-7, "queue overflow did not recover to silence");
}

void channelAllNotesOff() {
    constexpr double rate = 48000;
    auto synth = makeSynth(rate);
    fm_sustain(synth.get(), 0, 1);
    fm_sustain(synth.get(), 1, 1);
    fm_note_on(synth.get(), 0, 69, 100);
    fm_note_on(synth.get(), 1, 72, 100);
    render(synth.get(), rate, .1);
    fm_channel_all_notes_off(synth.get(), 0, 0);
    fm_note_off(synth.get(), 1, 72);
    render(synth.get(), rate, .2);
    const auto sustained = render(synth.get(), rate, .4);
    require(magnitude(sustained.left, rate, 440) > .001,
            "CC123 did not honor its channel sustain pedal");
    require(magnitude(sustained.left, rate, 523.2511306) > .001,
            "CC123 disturbed another channel sustain pedal");
    fm_sustain(synth.get(), 0, 0);
    render(synth.get(), rate, .2);
    const auto pedalUp = render(synth.get(), rate, .4);
    require(magnitude(pedalUp.left, rate, 440) < .00001,
            "CC123 did not mark held keys released for subsequent pedal up");
    require(magnitude(pedalUp.left, rate, 523.2511306) > .001,
            "channel zero pedal up disturbed another channel");
    fm_sustain(synth.get(), 0, 1);
    fm_note_on(synth.get(), 0, 69, 100);
    render(synth.get(), rate, .1);
    fm_channel_all_notes_off(synth.get(), 0, 1);
    render(synth.get(), rate, .1);
    const auto immediate = render(synth.get(), rate, .4);
    require(magnitude(immediate.left, rate, 440) < .00001,
            "CC120 did not silence its channel despite sustain");
    require(magnitude(immediate.left, rate, 523.2511306) > .001,
            "CC120 silenced the other channel");
    fm_sustain(synth.get(), 1, 0);
    render(synth.get(), rate, .2);
    require(peak(render(synth.get(), rate, .1)) < 1e-7,
            "channel controller tests left a stuck note");
}

void invalidInputs() {
    auto synth = makeSynth();
    const float values[] = {std::numeric_limits<float>::quiet_NaN(),
                            std::numeric_limits<float>::infinity(),
                            -std::numeric_limits<float>::infinity(), -1e30f, 1e30f};
    for (int parameter = 0; parameter < FM_PARAMETER_COUNT; ++parameter) {
        for (float value : values) {
            fm_set_parameter(synth.get(), parameter, value);
            require(std::isfinite(fm_get_parameter(synth.get(), parameter)),
                    "nonfinite parameter survived validation");
        }
    }
    fm_set_parameter(synth.get(), -1, 1);
    fm_set_parameter(synth.get(), FM_PARAMETER_COUNT + 20, 1);
    fm_note_on(synth.get(), -1, -40, -1);
    fm_note_off(synth.get(), 99, 1000);
    fm_pitch_bend(synth.get(), 0, std::numeric_limits<float>::quiet_NaN());
    fm_note_on(synth.get(), 0, 69, 100);
    require(peak(render(synth.get(), 48000, 1)) <= 1.001, "extreme parameters produced unbounded output");
    dryParameters(synth.get());
    fm_all_notes_off(synth.get());
    render(synth.get(), 48000, .3);
    fm_note_on(synth.get(), 0, 69, 100);
    render(synth.get(), 48000, .2);
    require(rms(render(synth.get(), 48000, .2).left) > .001,
            "engine did not recover after invalid input");
}

void configureEffects(FMSynth *synth) {
    fm_set_parameter(synth, FM_DRIVE, .65f);
    fm_set_parameter(synth, FM_CHORUS_RATE, .8f);
    fm_set_parameter(synth, FM_CHORUS_DEPTH, .8f);
    fm_set_parameter(synth, FM_PHASER_RATE, .5f);
    fm_set_parameter(synth, FM_PHASER_DEPTH, .8f);
    fm_set_parameter(synth, FM_DELAY_TIME, .16f);
    fm_set_parameter(synth, FM_DELAY_FEEDBACK, .45f);
    fm_set_parameter(synth, FM_REVERB_SIZE, .65f);
    fm_set_parameter(synth, FM_REVERB_DAMP, .45f);
}

void effects() {
    constexpr double rate = 48000;
    const std::pair<FMParameter, const char *> effects[] = {
        {FM_DRIVE_MIX, "distortion"}, {FM_CHORUS_MIX, "chorus"},
        {FM_PHASER_MIX, "phaser"}, {FM_DELAY_MIX, "delay"},
        {FM_REVERB_MIX, "reverb"}};
    for (const auto &effect : effects) {
        auto dry = makeSynth(rate);
        auto wet = makeSynth(rate);
        for (auto *synth : {dry.get(), wet.get()}) {
            configureEffects(synth);
            fm_set_parameter(synth, FM_MOD_INDEX, 1.5f);
        }
        fm_set_parameter(wet.get(), effect.first, .65f);
        render(dry.get(), rate, .3);
        render(wet.get(), rate, .3);
        fm_note_on(dry.get(), 0, 57, 110);
        fm_note_on(wet.get(), 0, 57, 110);
        const auto dryAudio = render(dry.get(), rate, 1.5);
        const auto wetAudio = render(wet.get(), rate, 1.5);
        require(difference(dryAudio, wetAudio) > rms(dryAudio.left) * .01,
                std::string(effect.second) + " did not independently change audio");
        require(peak(wetAudio) <= 1.001, std::string(effect.second) + " output unbounded");
        fm_note_off(wet.get(), 0, 57);
        auto tail = render(wet.get(), rate, 8);
        require(peak(tail) <= 1.001, std::string(effect.second) + " tail unstable");
        require(windowRMS(tail.left, rate, 7, 8) < .002,
                std::string(effect.second) + " tail failed to decay");
        if (effect.first == FM_DELAY_MIX || effect.first == FM_REVERB_MIX) {
            require(windowRMS(tail.left, rate, .1, .3) > .00001,
                    std::string(effect.second) + " had no audible post-note tail");
        }
    }

    // Distortion must create harmonics, rather than merely change the gain.
    auto drive = makeSynth(rate);
    fm_note_on(drive.get(), 0, 69, 100);
    render(drive.get(), rate, .2);
    auto cleanSine = render(drive.get(), rate, .5);
    const double cleanRatio = magnitude(cleanSine.left, rate, 1320) /
                              magnitude(cleanSine.left, rate, 440);
    fm_set_parameter(drive.get(), FM_DRIVE, .85f);
    fm_set_parameter(drive.get(), FM_DRIVE_MIX, 1);
    render(drive.get(), rate, .2);
    auto distortedSine = render(drive.get(), rate, .5);
    const double distortedRatio = magnitude(distortedSine.left, rate, 1320) /
                                  magnitude(distortedSine.left, rate, 440);
    require(distortedRatio > .01 && distortedRatio > cleanRatio * 5,
            "distortion changed gain without adding expected harmonics");
}

Audio blockScenario(uint32_t block, double rate) {
    auto synth = makeSynth(rate);
    configureEffects(synth.get());
    fm_set_parameter(synth.get(), FM_MOD_INDEX, 2.3f);
    for (auto mix : {FM_DRIVE_MIX, FM_CHORUS_MIX, FM_PHASER_MIX,
                     FM_DELAY_MIX, FM_REVERB_MIX}) fm_set_parameter(synth.get(), mix, .35f);
    render(synth.get(), rate, .3, block);
    Audio result;
    const auto append = [&](const Audio &part) {
        result.left.insert(result.left.end(), part.left.begin(), part.left.end());
        result.right.insert(result.right.end(), part.right.begin(), part.right.end());
    };
    fm_note_on(synth.get(), 0, 60, 100);
    fm_note_on(synth.get(), 0, 67, 80);
    append(render(synth.get(), rate, .4, block));
    fm_pitch_bend(synth.get(), 0, -.7f);
    fm_set_parameter(synth.get(), FM_MOD_INDEX, .8f);
    append(render(synth.get(), rate, .2, block));
    fm_note_off(synth.get(), 0, 60);
    fm_note_off(synth.get(), 0, 67);
    append(render(synth.get(), rate, .4, block));
    return result;
}

void blockSizesAndTelemetry() {
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        const auto reference = blockScenario(128, rate);
        for (uint32_t block : {1u, 31u, 257u, 1024u}) {
            const auto candidate = blockScenario(block, rate);
            require(difference(reference, candidate) < 2e-5,
                    "audio depends on callback block size " + std::to_string(block));
            require(peak(candidate) <= 1.001, "all-effects audio is not bounded");
        }
    }
    auto synth = makeSynth();
    fm_note_on(synth.get(), 0, 69, 100);
    render(synth.get(), 48000, .2);
    float waveform[1026];
    std::fill(std::begin(waveform), std::end(waveform), 9876.0f);
    const uint32_t copied = fm_copy_waveform(synth.get(), waveform + 1, 1024);
    require(copied > 0 && copied <= 1024, "invalid telemetry waveform length");
    require(waveform[0] == 9876 && waveform[1025] == 9876, "telemetry overwrote destination bounds");
    for (uint32_t i = 0; i < copied; ++i)
        require(std::isfinite(waveform[i + 1]) && std::abs(waveform[i + 1]) <= 1.001,
                "invalid telemetry waveform sample");
    require(std::isfinite(fm_peak_level(synth.get())) && fm_peak_level(synth.get()) > 0,
            "peak telemetry is invalid");
}

void concurrentStress() {
    auto synth = makeSynth();
    std::atomic<bool> start{false}, producersDone{false}, failed{false};
    std::atomic<size_t> allocations{0};
    std::thread audio([&] {
        float left[128], right[128];
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        size_t blocks = 0;
        while (!producersDone.load(std::memory_order_acquire) || blocks < 5000) {
            countRenderAllocations = true;
            fm_render(synth.get(), left, right, 128);
            countRenderAllocations = false;
            for (float value : left)
                if (!std::isfinite(value) || std::abs(value) > 1.001) failed = true;
            for (float value : right)
                if (!std::isfinite(value) || std::abs(value) > 1.001) failed = true;
            ++blocks;
        }
        allocations = renderAllocations;
    });
    std::vector<std::thread> producers;
    for (int producer = 0; producer < 4; ++producer) {
        producers.emplace_back([&, producer] {
            while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
            float waveform[257];
            for (int i = 0; i < 12000; ++i) {
                const int channel = producer;
                const int note = 36 + (i % 60);
                switch (i % 7) {
                case 0: fm_note_on(synth.get(), channel, note, 80 + i % 40); break;
                case 1: fm_note_off(synth.get(), channel, 36 + ((i - 1) % 60)); break;
                case 2: fm_sustain(synth.get(), channel, (i / 7) % 2); break;
                case 3: fm_pitch_bend(synth.get(), channel, float(i % 5) - 2); break;
                case 4: fm_set_parameter(synth.get(), FM_MOD_INDEX, float(i % 30) / 10); break;
                case 5: fm_set_parameter(synth.get(), FM_MASTER, .1f + float(i % 5) / 20); break;
                default: {
                    const auto count = fm_copy_waveform(synth.get(), waveform, 257);
                    if (count > 257 || !std::isfinite(fm_peak_level(synth.get())) ||
                        !std::isfinite(fm_get_parameter(synth.get(), FM_MASTER))) failed = true;
                    for (uint32_t j = 0; j < std::min(count, 257u); ++j)
                        if (!std::isfinite(waveform[j]) || std::abs(waveform[j]) > 1.001) failed = true;
                    break;
                }
                }
            }
        });
    }
    start.store(true, std::memory_order_release);
    for (auto &producer : producers) producer.join();
    producersDone.store(true, std::memory_order_release);
    audio.join();
    require(!failed, "concurrent producers/render/telemetry violated output invariants");
    require(allocations == 0, "concurrent rendering allocated C++ heap memory");
    fm_all_notes_off(synth.get());
    render(synth.get(), 48000, .3);
    require(fm_active_voices(synth.get()) == 0, "concurrent stress left stuck voices after panic");
    require(peak(render(synth.get(), 48000, .1)) < 1e-7, "stress recovery is not silent");
}

void benchmark(const char *label, int voices, bool allEffects) {
    constexpr double rate = 48000;
    constexpr uint32_t block = 128;
    constexpr size_t iterations = 6000;
    auto synth = makeSynth(rate);
    fm_set_parameter(synth.get(), FM_MOD_INDEX, 3.5f);
    if (allEffects) {
        configureEffects(synth.get());
        for (auto mix : {FM_DRIVE_MIX, FM_CHORUS_MIX, FM_PHASER_MIX,
                         FM_DELAY_MIX, FM_REVERB_MIX}) fm_set_parameter(synth.get(), mix, .4f);
    }
    for (int i = 0; i < voices; ++i) fm_note_on(synth.get(), i % 16, 36 + i, 100);
    render(synth.get(), rate, .2);
    require(fm_active_voices(synth.get()) == voices,
            std::string(label) + " benchmark did not sustain its requested voice count");
    float left[block], right[block];
    std::vector<double> micros(iterations);
    const size_t before = renderAllocations;
    countRenderAllocations = true;
    for (size_t i = 0; i < iterations; ++i) {
        const auto started = std::chrono::steady_clock::now();
        fm_render(synth.get(), left, right, block);
        const auto finished = std::chrono::steady_clock::now();
        micros[i] = std::chrono::duration<double, std::micro>(finished - started).count();
    }
    countRenderAllocations = false;
    require(renderAllocations == before, "benchmark render allocated C++ heap memory");
    std::sort(micros.begin(), micros.end());
    const double budget = double(block) / rate * 1e6;
    const auto percentile = [&](double p) { return micros[size_t(p * double(iterations - 1))]; };
    std::printf("%-24s %8.2f %8.2f %8.2f %8.2f us | %6.2f %6.2f %6.2f %6.2f %%\n",
                label, percentile(.5), percentile(.95), percentile(.99), micros.back(),
                100 * percentile(.5) / budget, 100 * percentile(.95) / budget,
                100 * percentile(.99) / budget, 100 * micros.back() / budget);
    require(percentile(.99) < budget * .25,
            std::string(label) + " p99 used over 25% of callback budget (75% headroom required)");
    require(micros.back() < budget,
            std::string(label) + " maximum callback exceeded the 128-frame audio deadline");
}
} // namespace

int main(int argc, char **argv) {
    bool tests = true, stress = true, benchmarks = true;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg == "--benchmark-only") { tests = false; stress = false; }
        else if (arg == "--stress-only") { tests = false; benchmarks = false; }
        else if (arg == "--no-benchmark") benchmarks = false;
        else if (arg == "--no-stress") stress = false;
        else { std::fprintf(stderr, "Unknown test argument: %s\n", argv[i]); return 2; }
    }
    int failures = 0;
    const auto run = [&](const char *name, const std::function<void()> &test) {
        try { test(); std::printf("PASS %s\n", name); }
        catch (const std::exception &error) {
            ++failures;
            std::fprintf(stderr, "FAIL %s: %s\n", name, error.what());
        }
        std::fflush(stdout);
    };
    if (tests) {
        run("silence, sine purity, A4 pitch, amplitude, 44.1/48/96 kHz", silenceAndSine);
        run("FM sidebands against Bessel predictions at 44.1/48/96 kHz", fmSidebands);
        run("independent envelopes and velocity", envelopesAndVelocity);
        run("polyphonic chord, per-channel sustain/bend, zero velocity", midiAndPolyphony);
        run("CC120/CC123 channel isolation and sustain semantics", channelAllNotesOff);
        run("retrigger, voice stealing, event overflow recovery", repeatedNotesStealingAndOverflow);
        run("nonfinite and extreme parameter/input recovery", invalidInputs);
        run("five independent effects and bounded decaying tails", effects);
        run("block-size invariance, sample rates, bounded telemetry", blockSizesAndTelemetry);
    }
    if (stress) run("four concurrent control/telemetry producers and render", concurrentStress);
    if (benchmarks) {
        std::puts("\n48 kHz, 128-frame callbacks, 2666.67 us audio budget; 6000 samples per case.");
        std::puts("Case                       median      p95      p99      max    | median    p95    p99    max budget");
        run("performance harness", [&] {
            benchmark("idle / effects bypassed", 0, false);
            benchmark("8 voices / five effects", 8, true);
            benchmark("24 voices / five effects", 24, true);
        });
        std::puts("Timing includes scheduler interruptions; maximum is not a hard realtime guarantee.");
    }
    std::printf("\n%d failed groups. Every render call checked for C++ new/new[] allocations.\n", failures);
    if (!failures && tests && stress && benchmarks) std::puts("DSP_TESTS_PASS");
    return failures ? 1 : 0;
}
