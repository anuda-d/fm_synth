#include "FMSynth.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

namespace {
constexpr int kPolyphony = 24;
constexpr int kStealTails = 8;
constexpr int kChannels = 16;
constexpr int kTableBits = 13;
constexpr int kTableSize = 1 << kTableBits;
constexpr int kQueueSize = 1024;
constexpr int kWaveSize = 256;
constexpr int kFIRTaps = 31;
constexpr double kPi = 3.1415926535897932384626433832795;
constexpr float kInvTwoPi = 0.15915494309189533577f;
static_assert(std::atomic<float>::is_always_lock_free, "Realtime float atomics required");
static_assert(std::atomic<int>::is_always_lock_free, "Realtime voice-count atomics required");
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Realtime event atomics required");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "Realtime telemetry atomics required");

struct ParameterSpec { float low, high, initial; };
constexpr ParameterSpec kSpecs[FM_PARAMETER_COUNT] = {
    {0, 1, .72f}, {.25f, 8, 1}, {.25f, 16, 2}, {0, 12, 2.5f},
    {.001f, 8, .008f}, {.005f, 12, .5f}, {0, 1, .55f}, {.008f, 16, .65f},
    {.001f, 8, .003f}, {.005f, 12, .7f}, {0, 1, .15f}, {.008f, 16, .45f},
    {0, 1, .8f}, {0, 1, .3f}, {0, 1, 0},
    {.05f, 5, .35f}, {0, 1, .45f}, {0, 1, 0},
    {.03f, 5, .2f}, {0, 1, .6f}, {0, 1, 0},
    {.03f, 2, .32f}, {0, .9f, .35f}, {0, 1, 0},
    {0, 1, .55f}, {0, 1, .45f}, {0, 1, 0}
};

float noDenormal(float value) { return std::abs(value) < 1.e-20f ? 0.f : value; }
float softClip(float x) {
    // Bounded rational approximation of tanh, with zero slope at the endpoints.
    if (x >= 3.f) return 1.f;
    if (x <= -3.f) return -1.f;
    const float x2 = x * x;
    return x * (27.f + x2) / (27.f + 9.f * x2);
}

enum class EventType : uint8_t { NoteOn, NoteOff, Sustain, Bend, ChannelNotesOff };
struct Event {
    EventType type{};
    uint8_t channel = 0, note = 0, velocity = 0;
    float value = 0;
    uint32_t generation = 0;
};

// Bounded MPSC ring. A sequence number owns each slot until its producer has
// published the payload. Render never waits for an interrupted producer.
class EventQueue {
    struct Slot { std::atomic<uint64_t> sequence{0}; Event event{}; };
    std::array<Slot, kQueueSize> slots_{};
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) uint64_t read_ = 0; // Accessed only by the render consumer.
public:
    EventQueue() {
        for (uint64_t i = 0; i < kQueueSize; ++i)
            slots_[i].sequence.store(i, std::memory_order_relaxed);
    }
    bool push(const Event &event) {
        uint64_t position = write_.load(std::memory_order_relaxed);
        // Bound control-thread contention as well as queue capacity.
        for (int attempt = 0; attempt < 32; ++attempt) {
            Slot &slot = slots_[position & (kQueueSize - 1)];
            const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
            const int64_t difference = static_cast<int64_t>(sequence - position);
            if (difference == 0) {
                if (write_.compare_exchange_weak(position, position + 1,
                                                std::memory_order_relaxed)) {
                    slot.event = event;
                    slot.sequence.store(position + 1, std::memory_order_release);
                    return true;
                }
            } else if (difference < 0) {
                return false;
            } else {
                position = write_.load(std::memory_order_relaxed);
            }
        }
        return false;
    }
    bool pop(Event &event) {
        Slot &slot = slots_[read_ & (kQueueSize - 1)];
        if (slot.sequence.load(std::memory_order_acquire) != read_ + 1) return false;
        event = slot.event;
        slot.sequence.store(read_ + kQueueSize, std::memory_order_release);
        ++read_;
        return true;
    }
};

struct EnvelopeSettings {
    float attackStep = 1, decayCoefficient = 0, sustain = 1;
    float sustainCoefficient = 0, releaseCoefficient = 0;
    uint32_t decayFrames = 1, releaseFrames = 1;
    void set(float attack, float decay, float level, float release, double rate) {
        attackStep = 1.f / static_cast<float>(std::max(1.0, attack * rate));
        decayFrames = static_cast<uint32_t>(std::max(1.0, decay * rate));
        releaseFrames = static_cast<uint32_t>(std::max(1.0, release * rate));
        decayCoefficient = static_cast<float>(std::exp(std::log(.001) / decayFrames));
        releaseCoefficient = static_cast<float>(std::exp(std::log(.0001) / releaseFrames));
        sustainCoefficient = static_cast<float>(1. - std::exp(-1. / (.005 * rate)));
        sustain = level;
    }
};

struct Envelope {
    enum Stage : uint8_t { Idle, Attack, Decay, Sustain, Release } stage = Idle;
    float value = 0, releaseCoefficient = 0;
    uint32_t elapsed = 0, releaseFrames = 1;
    void start() { stage = Attack; value = 0; elapsed = 0; }
    void release(const EnvelopeSettings &settings) {
        if (stage == Idle || stage == Release) return;
        stage = Release;
        elapsed = 0;
        releaseFrames = settings.releaseFrames;
        releaseCoefficient = settings.releaseCoefficient;
    }
    void quickRelease(double rate, float seconds) {
        if (stage == Idle) return;
        stage = Release;
        elapsed = 0;
        releaseFrames = static_cast<uint32_t>(std::max(1.0, seconds * rate));
        releaseCoefficient = static_cast<float>(std::exp(std::log(.0001) / releaseFrames));
    }
    float tick(const EnvelopeSettings &settings) {
        switch (stage) {
        case Attack:
            value += settings.attackStep;
            if (value >= 1.f) { value = 1; stage = Decay; elapsed = 0; }
            break;
        case Decay:
            value = settings.sustain + (value - settings.sustain) * settings.decayCoefficient;
            if (++elapsed >= settings.decayFrames) { value = settings.sustain; stage = Sustain; }
            break;
        case Sustain:
            value += (settings.sustain - value) * settings.sustainCoefficient;
            break;
        case Release:
            value *= releaseCoefficient;
            if (++elapsed >= releaseFrames || value < 1.e-8f) { value = 0; stage = Idle; }
            break;
        case Idle: break;
        }
        return value;
    }
};

struct Voice {
    bool active = false, keyDown = false;
    uint8_t channel = 0, note = 0;
    float velocity = 1, frequency = 440;
    double carrierPhase = 0, modulatorPhase = 0;
    uint64_t age = 0;
    Envelope amp{}, mod{};
};

struct DelayLine {
    std::vector<float> samples;
    size_t position = 0;
    void allocate(size_t length) { samples.assign(length, 0.f); position = 0; }
    float read(float delay) const {
        float index = static_cast<float>(position) - delay;
        const float length = static_cast<float>(samples.size());
        if (index < 0) index += length;
        const size_t first = static_cast<size_t>(index);
        const size_t second = first + 1 == samples.size() ? 0 : first + 1;
        const float fraction = index - static_cast<float>(first);
        return samples[first] + fraction * (samples[second] - samples[first]);
    }
    float current() const { return samples[position]; }
    void write(float value) {
        samples[position] = noDenormal(value);
        if (++position == samples.size()) position = 0;
    }
    void clear() { std::fill(samples.begin(), samples.end(), 0.f); position = 0; }
};

struct AllpassDelay {
    DelayLine delay;
    float tick(float input) {
        const float previous = delay.current();
        const float result = previous - .6f * input;
        delay.write(input + .6f * result);
        return result;
    }
};
} // namespace

struct FMSynth {
    const double rate, internalRate;
    std::array<std::atomic<float>, FM_PARAMETER_COUNT> targets{};
    std::array<float, FM_PARAMETER_COUNT> smooth{}, blockTargets{};
    std::array<float, kTableSize + 1> sineTable{};
    std::array<float, 128> noteFrequencies{};
    std::array<Voice, kPolyphony> voices{};
    std::array<Voice, kStealTails> tails{};
    std::array<bool, kChannels> sustain{};
    std::array<float, kChannels> bendTargets{}, bendMultipliers{};
    EnvelopeSettings ampSettings{}, modSettings{};
    EventQueue events;
    std::atomic<uint32_t> generation{0}, dropped{0};
    uint32_t handledGeneration = 0;
    uint64_t noteAge = 0;
    float smoothingCoefficient = 0, bendCoefficient = 0;
    std::array<float, kFIRTaps> firCoefficients{}, firHistory{};
    int firPosition = 0;
    DelayLine chorus, delayLeft, delayRight;
    double chorusPhase = 0, phaserPhase = 0;
    std::array<std::array<float, 6>, 2> phaserMemory{};
    std::array<float, 2> phaserFeedback{}, phaserCoefficient{}, phaserStep{};
    uint32_t phaserCounter = 0;
    std::array<DelayLine, 8> reverbLines;
    std::array<float, 8> reverbLowpass{};
    std::array<AllpassDelay, 4> diffusers;
    bool reverbDirty = false, phaserDirty = false;
    std::atomic<int> activeTelemetry{0};
    std::atomic<float> peakTelemetry{0};
    std::array<std::atomic<float>, kWaveSize> wave{};
    std::atomic<uint32_t> waveWrite{0};
    uint32_t waveformCounter = 0, waveformDivider = 1;

    explicit FMSynth(double sampleRate) : rate(sampleRate), internalRate(sampleRate * 2.) {
        for (int i = 0; i < FM_PARAMETER_COUNT; ++i) {
            targets[i].store(kSpecs[i].initial, std::memory_order_relaxed);
            smooth[i] = blockTargets[i] = kSpecs[i].initial;
        }
        for (int i = 0; i <= kTableSize; ++i)
            sineTable[i] = static_cast<float>(std::sin(2. * kPi * i / kTableSize));
        for (int i = 0; i < 128; ++i)
            noteFrequencies[i] = static_cast<float>(440. * std::exp2((i - 69.) / 12.));
        for (auto &sample : wave) sample.store(0, std::memory_order_relaxed);
        bendTargets.fill(1); bendMultipliers.fill(1);
        smoothingCoefficient = static_cast<float>(1. - std::exp(-1. / (.015 * rate)));
        bendCoefficient = static_cast<float>(1. - std::exp(-1. / (.010 * rate)));
        waveformDivider = std::max(1u, static_cast<uint32_t>(rate / 16000.));
        // Windowed-sinc low pass before 2:1 decimation. Its .225 internal-rate
        // cutoff deliberately leaves a transition band below output Nyquist.
        double sum = 0;
        for (int i = 0; i < kFIRTaps; ++i) {
            const int offset = i - (kFIRTaps - 1) / 2;
            const double sinc = offset == 0 ? .45 : std::sin(2. * kPi * .225 * offset) / (kPi * offset);
            const double window = .42 - .5 * std::cos(2. * kPi * i / (kFIRTaps - 1))
                                    + .08 * std::cos(4. * kPi * i / (kFIRTaps - 1));
            firCoefficients[i] = static_cast<float>(sinc * window);
            sum += firCoefficients[i];
        }
        for (float &coefficient : firCoefficients) coefficient /= static_cast<float>(sum);
        chorus.allocate(static_cast<size_t>(std::ceil(rate * .06)) + 2);
        delayLeft.allocate(static_cast<size_t>(std::ceil(rate * 2.05)) + 2);
        delayRight.allocate(static_cast<size_t>(std::ceil(rate * 2.05)) + 2);
        constexpr int lengths[8] = {1423, 1559, 1759, 1993, 2137, 2377, 2591, 2797};
        for (int i = 0; i < 8; ++i)
            reverbLines[i].allocate(std::max<size_t>(2, static_cast<size_t>(lengths[i] * rate / 44100.)));
        constexpr int diffusionLengths[4] = {229, 73, 241, 89};
        for (int i = 0; i < 4; ++i)
            diffusers[i].delay.allocate(std::max<size_t>(2, static_cast<size_t>(diffusionLengths[i] * rate / 44100.)));
        updateEnvelopeSettings();
    }

    float sine(double phase) const {
        // The caller bounds oscillator phase; PM can add at most 12 radians.
        const int64_t whole = static_cast<int64_t>(std::floor(phase));
        const float fraction = static_cast<float>(phase - static_cast<double>(whole));
        const uint32_t index = static_cast<uint32_t>(whole) & (kTableSize - 1);
        return sineTable[index] + fraction * (sineTable[index + 1] - sineTable[index]);
    }

    void enqueue(Event event) {
        event.generation = generation.load(std::memory_order_acquire);
        if (!events.push(event)) {
            dropped.fetch_add(1, std::memory_order_relaxed);
            // Invalidate pre-overflow note-ons, including a producer that was
            // descheduled while publishing a slot. Otherwise it could arrive
            // after panic and leave a voice with a lost note-off.
            generation.fetch_add(1, std::memory_order_acq_rel);
        }
    }

    void updateEnvelopeSettings() {
        ampSettings.set(blockTargets[FM_AMP_ATTACK], blockTargets[FM_AMP_DECAY],
                        blockTargets[FM_AMP_SUSTAIN], blockTargets[FM_AMP_RELEASE], internalRate);
        modSettings.set(blockTargets[FM_MOD_ATTACK], blockTargets[FM_MOD_DECAY],
                        blockTargets[FM_MOD_SUSTAIN], blockTargets[FM_MOD_RELEASE], internalRate);
    }

    void releaseVoice(Voice &voice) {
        voice.amp.release(ampSettings);
        voice.mod.release(modSettings);
    }

    void panic() {
        sustain.fill(false);
        for (Voice &voice : voices) {
            voice.keyDown = false;
            voice.amp.quickRelease(internalRate, .008f);
            voice.mod.quickRelease(internalRate, .008f);
        }
        for (Voice &voice : tails) {
            voice.amp.quickRelease(internalRate, .005f);
            voice.mod.quickRelease(internalRate, .005f);
        }
    }

    void beginNote(const Event &event) {
        for (Voice &voice : voices) {
            if (voice.active && voice.note == event.note && voice.channel == event.channel) {
                voice.keyDown = false;
                releaseVoice(voice);
            }
        }
        Voice *selected = nullptr;
        for (Voice &voice : voices) if (!voice.active) { selected = &voice; break; }
        if (!selected) {
            // Prefer a released voice, then the quietest held voice. Stable age
            // ordering prevents one newly struck note from repeatedly stealing.
            float best = std::numeric_limits<float>::max();
            for (Voice &voice : voices) {
                const float score = voice.amp.value * (.2f + .8f * voice.velocity)
                                    + (voice.keyDown ? 2.f : 0.f);
                if (score < best || (score == best && selected && voice.age < selected->age)) {
                    selected = &voice; best = score;
                }
            }
            Voice *tail = nullptr;
            for (Voice &candidate : tails) if (!candidate.active) { tail = &candidate; break; }
            if (!tail) {
                tail = &*std::min_element(tails.begin(), tails.end(), [](const Voice &a, const Voice &b) {
                    return a.amp.value * a.velocity < b.amp.value * b.velocity;
                });
            }
            *tail = *selected;
            tail->keyDown = false;
            tail->amp.quickRelease(internalRate, .005f);
            tail->mod.quickRelease(internalRate, .005f);
        }
        *selected = Voice{};
        selected->active = selected->keyDown = true;
        selected->channel = event.channel; selected->note = event.note;
        selected->velocity = event.velocity / 127.f;
        selected->frequency = noteFrequencies[event.note];
        selected->age = ++noteAge;
        selected->amp.start(); selected->mod.start();
    }

    void handleEvents() {
        uint32_t currentGeneration = generation.load(std::memory_order_acquire);
        if (handledGeneration != currentGeneration) {
            panic(); handledGeneration = currentGeneration;
        }
        Event event;
        for (int count = 0; count < kQueueSize && events.pop(event); ++count) {
            currentGeneration = generation.load(std::memory_order_acquire);
            if (handledGeneration != currentGeneration) {
                panic(); handledGeneration = currentGeneration;
            }
            if (event.generation != currentGeneration) continue;
            switch (event.type) {
            case EventType::NoteOn: beginNote(event); break;
            case EventType::NoteOff:
                for (Voice &voice : voices) {
                    if (voice.active && voice.channel == event.channel && voice.note == event.note) {
                        voice.keyDown = false;
                        if (!sustain[event.channel]) releaseVoice(voice);
                    }
                }
                break;
            case EventType::Sustain:
                sustain[event.channel] = event.value != 0;
                if (!sustain[event.channel]) {
                    for (Voice &voice : voices)
                        if (voice.active && voice.channel == event.channel && !voice.keyDown) releaseVoice(voice);
                }
                break;
            case EventType::Bend:
                bendTargets[event.channel] = std::exp2(event.value / 12.f);
                break;
            case EventType::ChannelNotesOff:
                for (Voice &voice : voices) {
                    if (!voice.active || voice.channel != event.channel) continue;
                    voice.keyDown = false;
                    if (event.value != 0) {
                        voice.amp.quickRelease(internalRate, .008f);
                        voice.mod.quickRelease(internalRate, .008f);
                    } else if (!sustain[event.channel]) {
                        releaseVoice(voice);
                    }
                }
                if (event.value != 0) {
                    for (Voice &voice : tails) {
                        if (!voice.active || voice.channel != event.channel) continue;
                        voice.amp.quickRelease(internalRate, .005f);
                        voice.mod.quickRelease(internalRate, .005f);
                    }
                }
                break;
            }
        }
    }

    float renderVoice(Voice &voice) {
        if (!voice.active) return 0;
        const float amplitude = voice.amp.tick(ampSettings);
        const float modulationEnvelope = voice.mod.tick(modSettings);
        if (voice.amp.stage == Envelope::Idle) { voice.active = false; return 0; }
        const float sensitivity = smooth[FM_VELOCITY];
        const float velocityGain = 1.f - sensitivity * (1.f - voice.velocity);
        const float modulationGain = 1.f - sensitivity * .7f * (1.f - voice.velocity);
        const double frequency = voice.frequency * bendMultipliers[voice.channel];
        // Frequencies beyond the internal Nyquist region are capped. The
        // output low-pass removes inaudible fundamentals, but extreme PM
        // sidebands can still alias; oversampling is mitigation, not a claim
        // of band-limited FM.
        const double carrierIncrement = std::min(frequency * smooth[FM_CARRIER_RATIO] / internalRate, .45) * kTableSize;
        const double modulatorIncrement = std::min(frequency * smooth[FM_MOD_RATIO] / internalRate, .45) * kTableSize;
        const float modulator = sine(voice.modulatorPhase);
        const double phaseOffset = modulator * modulationEnvelope * smooth[FM_MOD_INDEX]
                                   * modulationGain * (kTableSize * kInvTwoPi);
        const float output = sine(voice.carrierPhase + phaseOffset) * amplitude * velocityGain * .13f;
        voice.carrierPhase += carrierIncrement;
        voice.modulatorPhase += modulatorIncrement;
        if (voice.carrierPhase >= kTableSize) voice.carrierPhase -= kTableSize;
        if (voice.modulatorPhase >= kTableSize) voice.modulatorPhase -= kTableSize;
        return output;
    }

    float oscillatorSample() {
        float output = 0;
        for (Voice &voice : voices) output += renderVoice(voice);
        for (Voice &voice : tails) output += renderVoice(voice);
        const float mix = smooth[FM_DRIVE_MIX];
        if (mix > .00001f) {
            const float amount = smooth[FM_DRIVE];
            const float gain = 1.f + 31.f * amount * amount;
            const float distorted = softClip(output * gain) / std::sqrt(gain);
            output += (distorted - output) * mix;
        }
        return output;
    }

    float synthesize() {
        // Distortion is before the downsampling filter so its upper harmonics
        // receive the same anti-alias treatment as the FM oscillators.
        for (int sub = 0; sub < 2; ++sub) {
            firHistory[firPosition] = oscillatorSample();
            if (++firPosition == kFIRTaps) firPosition = 0;
        }
        float output = 0;
        int position = firPosition;
        for (int i = 0; i < kFIRTaps; ++i) {
            if (--position < 0) position = kFIRTaps - 1;
            output += firCoefficients[i] * firHistory[position];
        }
        return output;
    }

    void processChorus(float &left, float &right) {
        const float depth = smooth[FM_CHORUS_DEPTH];
        const float base = static_cast<float>(rate * .016);
        const float excursion = static_cast<float>(rate * .007) * depth;
        const float tapLeft = chorus.read(base + excursion * sine(chorusPhase));
        const float tapRight = chorus.read(base + excursion * sine(chorusPhase + kTableSize * .25));
        chorus.write((left + right) * .5f);
        const float mix = smooth[FM_CHORUS_MIX];
        left += (tapLeft - left) * (.5f * mix);
        right += (tapRight - right) * (.5f * mix);
        chorusPhase += smooth[FM_CHORUS_RATE] * kTableSize / rate;
        if (chorusPhase >= kTableSize) chorusPhase -= kTableSize;
    }

    void processPhaser(float &left, float &right) {
        const float mix = smooth[FM_PHASER_MIX];
        if (mix < .00001f) {
            if (phaserDirty) {
                for (auto &channel : phaserMemory) channel.fill(0);
                phaserFeedback.fill(0); phaserCoefficient.fill(0); phaserStep.fill(0);
                phaserCounter = 0; phaserDirty = false;
            }
            return;
        }
        phaserDirty = true;
        if (phaserCounter++ % 32 == 0) {
            for (int channel = 0; channel < 2; ++channel) {
                const float lfo = .5f + .5f * sine(phaserPhase + channel * kTableSize * .125);
                const float frequency = 240.f * std::exp2(3.4f * smooth[FM_PHASER_DEPTH] * lfo);
                const float tangent = static_cast<float>(std::tan(kPi * std::min<double>(frequency, rate * .35) / rate));
                const float coefficient = (1.f - tangent) / (1.f + tangent);
                phaserStep[channel] = (coefficient - phaserCoefficient[channel]) * (1.f / 32.f);
            }
        }
        float input[2] = {left, right};
        for (int channel = 0; channel < 2; ++channel) {
            phaserCoefficient[channel] += phaserStep[channel];
            const float coefficient = phaserCoefficient[channel];
            float value = input[channel] + .22f * smooth[FM_PHASER_DEPTH] * phaserFeedback[channel];
            for (float &memory : phaserMemory[channel]) {
                const float filtered = -coefficient * value + memory;
                memory = noDenormal(value + coefficient * filtered);
                value = filtered;
            }
            phaserFeedback[channel] = noDenormal(value);
            input[channel] += (value - input[channel]) * (.5f * mix);
        }
        left = input[0]; right = input[1];
        phaserPhase += smooth[FM_PHASER_RATE] * kTableSize / rate;
        if (phaserPhase >= kTableSize) phaserPhase -= kTableSize;
    }

    void processDelay(float &left, float &right) {
        const float time = smooth[FM_DELAY_TIME] * static_cast<float>(rate);
        const float delayedLeft = delayLeft.read(time);
        const float delayedRight = delayRight.read(time * 1.013f);
        const float feedback = smooth[FM_DELAY_FEEDBACK];
        const float mix = smooth[FM_DELAY_MIX];
        // Keep history advancing during bypass, but inject no new signal. This
        // avoids both a frozen old echo on re-enable and clearing large rings.
        const float injection = mix > .00001f ? 1.f : 0.f;
        delayLeft.write(left * injection + delayedRight * feedback);
        delayRight.write(right * injection + delayedLeft * feedback);
        left += delayedLeft * mix * .65f;
        right += delayedRight * mix * .65f;
    }

    void processReverb(float &left, float &right) {
        const float mix = smooth[FM_REVERB_MIX];
        if (mix < .00001f) {
            if (reverbDirty) {
                for (DelayLine &line : reverbLines) line.clear();
                for (AllpassDelay &diffuser : diffusers) diffuser.delay.clear();
                reverbLowpass.fill(0); reverbDirty = false;
            }
            return;
        }
        reverbDirty = true;
        const float inputLeft = diffusers[1].tick(diffusers[0].tick(left));
        const float inputRight = diffusers[3].tick(diffusers[2].tick(right));
        std::array<float, 8> taps{}, feedback{};
        const float damping = .05f + .9f * smooth[FM_REVERB_DAMP];
        for (int i = 0; i < 8; ++i) {
            taps[i] = reverbLines[i].current();
            reverbLowpass[i] = noDenormal(taps[i] * (1.f - damping) + reverbLowpass[i] * damping);
            feedback[i] = reverbLowpass[i];
        }
        // Normalized 8x8 Hadamard feedback matrix is orthogonal. Every delay
        // loop therefore has bounded gain (<1), independent of room settings.
        for (int stride = 1; stride < 8; stride *= 2) {
            for (int base = 0; base < 8; base += 2 * stride) {
                for (int i = 0; i < stride; ++i) {
                    const float a = feedback[base + i], b = feedback[base + i + stride];
                    feedback[base + i] = a + b;
                    feedback[base + i + stride] = a - b;
                }
            }
        }
        const float decay = (.65f + .32f * smooth[FM_REVERB_SIZE]) * .3535533905932738f;
        for (int i = 0; i < 8; ++i) {
            const float injection = ((i & 1) ? inputRight : inputLeft) * ((i & 2) ? -.13f : .13f);
            reverbLines[i].write(injection + feedback[i] * decay);
        }
        const float wetLeft = (taps[0] + taps[2] - taps[4] + taps[6]) * .38f;
        const float wetRight = (taps[1] + taps[3] - taps[5] + taps[7]) * .38f;
        left += wetLeft * mix;
        right += wetRight * mix;
    }

    void render(float *left, float *right, uint32_t frames) {
        if (!left || !right || frames == 0) return;
        for (int i = 0; i < FM_PARAMETER_COUNT; ++i)
            blockTargets[i] = targets[i].load(std::memory_order_relaxed);
        updateEnvelopeSettings();
        handleEvents();
        float peak = 0;
        for (uint32_t frame = 0; frame < frames; ++frame) {
            for (int i = 0; i < FM_PARAMETER_COUNT; ++i) {
                smooth[i] += (blockTargets[i] - smooth[i]) * smoothingCoefficient;
                // Reach exact bypass and stop accumulating denormal differences.
                if (std::abs(blockTargets[i] - smooth[i]) < 1.e-6f) smooth[i] = blockTargets[i];
            }
            for (int channel = 0; channel < kChannels; ++channel)
                bendMultipliers[channel] += (bendTargets[channel] - bendMultipliers[channel]) * bendCoefficient;
            float sampleLeft = synthesize(), sampleRight = sampleLeft;
            processChorus(sampleLeft, sampleRight);
            processPhaser(sampleLeft, sampleRight);
            processDelay(sampleLeft, sampleRight);
            processReverb(sampleLeft, sampleRight);
            sampleLeft = softClip(sampleLeft * smooth[FM_MASTER]);
            sampleRight = softClip(sampleRight * smooth[FM_MASTER]);
            left[frame] = sampleLeft; right[frame] = sampleRight;
            peak = std::max(peak, std::max(std::abs(sampleLeft), std::abs(sampleRight)));
            if (++waveformCounter >= waveformDivider) {
                waveformCounter = 0;
                const uint32_t index = waveWrite.load(std::memory_order_relaxed);
                wave[index & (kWaveSize - 1)].store(sampleLeft, std::memory_order_relaxed);
                waveWrite.store(index + 1, std::memory_order_release);
            }
        }
        int active = 0;
        for (const Voice &voice : voices) active += voice.active;
        for (const Voice &voice : tails) active += voice.active;
        activeTelemetry.store(active, std::memory_order_relaxed);
        peakTelemetry.store(peak, std::memory_order_relaxed);
    }
};

extern "C" {
FMSynth *fm_create(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate < 8000 || sample_rate > 192000) return nullptr;
    try { return new FMSynth(sample_rate); } catch (...) { return nullptr; }
}
void fm_destroy(FMSynth *synth) { delete synth; }
void fm_set_parameter(FMSynth *synth, int parameter, float value) {
    if (!synth || parameter < 0 || parameter >= FM_PARAMETER_COUNT) return;
    if (!std::isfinite(value)) value = kSpecs[parameter].initial;
    synth->targets[parameter].store(std::clamp(value, kSpecs[parameter].low, kSpecs[parameter].high), std::memory_order_relaxed);
}
float fm_get_parameter(const FMSynth *synth, int parameter) {
    if (!synth || parameter < 0 || parameter >= FM_PARAMETER_COUNT) return 0;
    return synth->targets[parameter].load(std::memory_order_relaxed);
}
void fm_note_on(FMSynth *synth, int channel, int note, int velocity) {
    if (!synth || channel < 0 || channel >= kChannels || note < 0 || note > 127) return;
    if (velocity <= 0) { fm_note_off(synth, channel, note); return; }
    Event event; event.type = EventType::NoteOn;
    event.channel = static_cast<uint8_t>(channel); event.note = static_cast<uint8_t>(note);
    event.velocity = static_cast<uint8_t>(std::min(127, velocity));
    synth->enqueue(event);
}
void fm_note_off(FMSynth *synth, int channel, int note) {
    if (!synth || channel < 0 || channel >= kChannels || note < 0 || note > 127) return;
    Event event; event.type = EventType::NoteOff;
    event.channel = static_cast<uint8_t>(channel); event.note = static_cast<uint8_t>(note);
    synth->enqueue(event);
}
void fm_sustain(FMSynth *synth, int channel, int down) {
    if (!synth || channel < 0 || channel >= kChannels) return;
    Event event; event.type = EventType::Sustain;
    event.channel = static_cast<uint8_t>(channel); event.value = down != 0 ? 1.f : 0.f;
    synth->enqueue(event);
}
void fm_pitch_bend(FMSynth *synth, int channel, float semitones) {
    if (!synth || channel < 0 || channel >= kChannels) return;
    Event event; event.type = EventType::Bend;
    event.channel = static_cast<uint8_t>(channel);
    event.value = std::isfinite(semitones) ? std::clamp(semitones, -12.f, 12.f) : 0.f;
    synth->enqueue(event);
}
void fm_all_notes_off(FMSynth *synth) {
    if (synth) synth->generation.fetch_add(1, std::memory_order_acq_rel);
}
void fm_channel_all_notes_off(FMSynth *synth, int channel, int immediate) {
    if (!synth || channel < 0 || channel >= kChannels) return;
    Event event; event.type = EventType::ChannelNotesOff;
    event.channel = static_cast<uint8_t>(channel); event.value = immediate != 0 ? 1.f : 0.f;
    synth->enqueue(event);
}
void fm_render(FMSynth *synth, float *left, float *right, uint32_t frames) {
    if (synth) synth->render(left, right, frames);
    else {
        if (left) std::fill_n(left, frames, 0.f);
        if (right) std::fill_n(right, frames, 0.f);
    }
}
int fm_active_voices(const FMSynth *synth) {
    return synth ? synth->activeTelemetry.load(std::memory_order_relaxed) : 0;
}
float fm_peak_level(const FMSynth *synth) {
    return synth ? synth->peakTelemetry.load(std::memory_order_relaxed) : 0;
}
uint32_t fm_dropped_events(const FMSynth *synth) {
    return synth ? synth->dropped.load(std::memory_order_relaxed) : 0;
}
uint32_t fm_copy_waveform(const FMSynth *synth, float *output, uint32_t capacity) {
    if (!synth || !output) return 0;
    const uint32_t end = synth->waveWrite.load(std::memory_order_acquire);
    const uint32_t count = std::min<uint32_t>(capacity, kWaveSize);
    for (uint32_t i = 0; i < count; ++i)
        output[i] = synth->wave[(end - count + i) & (kWaveSize - 1)].load(std::memory_order_relaxed);
    // Individual atomic points make concurrent UI reads race-free. A snapshot
    // can straddle two render blocks; it is a visualizer, not an audio recorder.
    return count;
}
} // extern "C"
