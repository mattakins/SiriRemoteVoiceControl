#include <ctype.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "opus/opus.h"

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} Bytes;

static void append_bytes(Bytes *b, const uint8_t *data, size_t len) {
    if (b->len + len > b->cap) {
        size_t next = b->cap ? b->cap * 2 : 4096;
        while (next < b->len + len) next *= 2;
        b->data = (uint8_t *)realloc(b->data, next);
        b->cap = next;
    }
    memcpy(b->data + b->len, data, len);
    b->len += len;
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static size_t parse_hex_bytes(const char *s, uint8_t *out, size_t max) {
    size_t n = 0;
    while (*s && n < max) {
        while (*s && !isxdigit((unsigned char)*s)) s++;
        if (!s[0] || !s[1]) break;
        int hi = hex_value(s[0]);
        int lo = hex_value(s[1]);
        if (hi < 0 || lo < 0) break;
        out[n++] = (uint8_t)((hi << 4) | lo);
        s += 2;
    }
    return n;
}

static int has_suffix(const uint8_t *data, size_t len, const uint8_t *suffix, size_t suffix_len) {
    return len >= suffix_len && memcmp(data + len - suffix_len, suffix, suffix_len) == 0;
}

static void write_le16(FILE *f, uint16_t v) {
    fputc(v & 0xff, f);
    fputc((v >> 8) & 0xff, f);
}

static void write_le32(FILE *f, uint32_t v) {
    fputc(v & 0xff, f);
    fputc((v >> 8) & 0xff, f);
    fputc((v >> 16) & 0xff, f);
    fputc((v >> 24) & 0xff, f);
}

static void write_wav(const char *path, const int16_t *pcm, size_t samples) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(1);
    }
    uint32_t data_bytes = (uint32_t)(samples * sizeof(int16_t));
    fwrite("RIFF", 1, 4, f);
    write_le32(f, 36 + data_bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    write_le32(f, 16);
    write_le16(f, 1);
    write_le16(f, 1);
    write_le32(f, 16000);
    write_le32(f, 16000 * 2);
    write_le16(f, 2);
    write_le16(f, 16);
    fwrite("data", 1, 4, f);
    write_le32(f, data_bytes);
    fwrite(pcm, sizeof(int16_t), samples, f);
    fclose(f);
}

static uint64_t monotonic_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static int meter_level_from_peak(int peak) {
    if (peak <= 0) return 0;
    double dbfs = 20.0 * log10((double)peak / 32767.0);
    int level = (int)((dbfs + 60.0) * 100.0 / 60.0);
    if (level < 0) return 0;
    if (level > 100) return 100;
    return level;
}

static int emit_wav_meter(const char *path) {
    FILE *in = fopen(path, "rb");
    if (!in) {
        perror(path);
        return 1;
    }

    /* Captures written above are fixed 16 kHz, mono, PCM16 WAV files. */
    if (fseek(in, 44, SEEK_SET) != 0) {
        perror(path);
        fclose(in);
        return 1;
    }

    int16_t samples[320]; /* 20 ms at 16 kHz */
    struct timespec interval = { .tv_sec = 0, .tv_nsec = 20000000 };
    while (1) {
        size_t count = fread(samples, sizeof(int16_t), 320, in);
        if (count == 0) break;

        int peak = 0;
        for (size_t i = 0; i < count; i++) {
            int value = samples[i] < 0 ? -(int)samples[i] : samples[i];
            if (value > peak) peak = value;
        }
        printf("%d\n", meter_level_from_peak(peak));
        fflush(stdout);
        nanosleep(&interval, NULL);
    }

    fclose(in);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--wav-meter") == 0) {
        return emit_wav_meter(argv[2]);
    }

    if (argc != 3) {
        fprintf(stderr, "Usage: %s packetlogger.txt out.wav\n", argv[0]);
        return 2;
    }

    FILE *in = strcmp(argv[1], "-") == 0 ? stdin : fopen(argv[1], "r");
    if (!in) {
        perror(argv[1]);
        return 1;
    }
    int raw_stdout = strcmp(argv[2], "-") == 0;

    int err = 0;
    OpusDecoder *decoder = opus_decoder_create(16000, 1, &err);
    if (!decoder || err != OPUS_OK) {
        fprintf(stderr, "opus_decoder_create failed: %d\n", err);
        return 1;
    }

    const uint8_t voice_start[] = {0x1B, 0x23, 0x00, 0x00, 0x10};
    const uint8_t voice_end[] = {0x1B, 0x23, 0x00, 0x10, 0x00};

    char line[4096];
    uint8_t bytes[512];
    uint8_t frame[512];
    size_t frame_len = 0;
    int voice = 0;
    int audio_notified = 0;
    int meter_display = 0;
    int frames = 0;
    Bytes pcm = {0};
    Bytes capture = {0};
    const char *capture_path = getenv("A1962_CAPTURE_WAV");
    static const int16_t silence[320] = {0}; /* 20 ms at 16 kHz */
    uint64_t last_output_ms = 0;

#define PROCESS_LINE() do { \
        char *recv = strstr(line, " RECV  "); \
        if (!recv) break; \
        size_t n = parse_hex_bytes(recv + 7, bytes, sizeof(bytes)); \
        if (n == 0) break; \
        if (has_suffix(bytes, n, voice_start, sizeof(voice_start))) { voice = 1; audio_notified = 0; meter_display = 0; frame_len = 0; capture.len = 0; if (raw_stdout) { fputs("EVENT audio_started\n", stderr); fflush(stderr); } break; } \
        if (has_suffix(bytes, n, voice_end,   sizeof(voice_end)))   { voice = 0; frame_len = 0; if (raw_stdout) { if (capture_path && capture.len > 0) write_wav(capture_path, (const int16_t *)capture.data, capture.len / sizeof(int16_t)); fputs("METER 0\nEVENT audio_ended\n", stderr); fflush(stderr); } break; } \
        if (!voice || n != 31) break; \
        if (bytes[1] == 0x20 && bytes[18] == 0xB8) { \
            if (frame_len > 1) { \
                uint8_t packet_len = frame[0]; \
                if ((size_t)packet_len < frame_len) { \
                    int16_t decoded[1920]; \
                    int samples = opus_decode(decoder, frame + 1, packet_len, decoded, 1920, 0); \
                    if (samples > 0) { \
                        if (raw_stdout) { \
                            fwrite(decoded, sizeof(int16_t), (size_t)samples, stdout); fflush(stdout); append_bytes(&capture, (const uint8_t *)decoded, (size_t)samples * sizeof(int16_t)); last_output_ms = monotonic_millis(); \
                            if (!audio_notified) { fputs("EVENT audio_received\n", stderr); fflush(stderr); audio_notified = 1; } \
                            fputs("EVENT audio_packet\n", stderr); fflush(stderr); \
                            { \
                                int frame_peak = 0; \
                                for (int i = 0; i < samples; i++) { int value = decoded[i] < 0 ? -decoded[i] : decoded[i]; if (value > frame_peak) frame_peak = value; } \
                                int target_level = meter_level_from_peak(frame_peak); \
                                if (target_level >= meter_display) meter_display = target_level; \
                                else if (meter_display - target_level > 4) meter_display -= 4; \
                                else meter_display = target_level; \
                                if (frame_peak >= 400) { fputs("EVENT audio_voiced_packet\n", stderr); fflush(stderr); } \
                                fprintf(stderr, "METER %d\n", meter_display); fflush(stderr); \
                            } \
                        } \
                        else { append_bytes(&pcm, (const uint8_t *)decoded, (size_t)samples * sizeof(int16_t)); } \
                        frames++; \
                    } \
                } \
            } \
            frame_len = 0; \
            memcpy(frame, bytes + 17, n - 17); \
            frame_len = n - 17; \
        } else if (frame_len > 0 && bytes[1] == 0x10) { \
            memcpy(frame + frame_len, bytes + 4, n - 4); \
            frame_len += n - 4; \
        } \
    } while (0)

    if (raw_stdout) {
        /* PacketLogger continuously emits unrelated BT traffic, so a poll timeout
           is not a reliable indicator of PCM inactivity. Keep the audio clock
           moving based on time since the last decoded audio frame instead. */
        int in_fd = fileno(in);
        size_t lpos = 0;
        char input_buffer[1024];
        last_output_ms = monotonic_millis();
        while (1) {
            struct pollfd pfd = { .fd = in_fd, .events = POLLIN };
            int rc = poll(&pfd, 1, 20);
            if (rc < 0) break;
            uint64_t now = monotonic_millis();
            if (now - last_output_ms >= 20) {
                fwrite(silence, sizeof(int16_t), 320, stdout);
                fflush(stdout);
                last_output_ms = now;
            }
            if (rc == 0) continue;
            /* Drain available trace data in chunks so audio frames do not queue
               behind unrelated Bluetooth log lines. */
            ssize_t nr = read(in_fd, input_buffer, sizeof(input_buffer));
            if (nr <= 0) break;
            for (ssize_t i = 0; i < nr; i++) {
                char c = input_buffer[i];
                if (lpos < sizeof(line) - 1) line[lpos++] = c;
                if (c == '\n') {
                    line[lpos] = '\0';
                    lpos = 0;
                    PROCESS_LINE();
                }
            }
        }
    } else {
        /* File mode: simple fgets loop, no silence padding needed. */
        while (fgets(line, sizeof(line), in)) {
            PROCESS_LINE();
        }
    }

    if (frame_len > 1) {
        uint8_t packet_len = frame[0];
        if ((size_t)packet_len < frame_len) {
            int16_t decoded[1920];
            int samples = opus_decode(decoder, frame + 1, packet_len, decoded, 1920, 0);
            if (samples > 0) {
                if (raw_stdout) {
                    fwrite(decoded, sizeof(int16_t), (size_t)samples, stdout);
                    fflush(stdout);
                } else {
                    append_bytes(&pcm, (const uint8_t *)decoded, (size_t)samples * sizeof(int16_t));
                }
                frames++;
            }
        }
    }

    if (in != stdin) fclose(in);
    opus_decoder_destroy(decoder);

    if (!raw_stdout) {
        write_wav(argv[2], (const int16_t *)pcm.data, pcm.len / sizeof(int16_t));
    }
    fprintf(stderr, "decoded_frames=%d pcm_samples=%zu\n", frames, pcm.len / sizeof(int16_t));
    free(capture.data);
    free(pcm.data);
    return 0;
}
