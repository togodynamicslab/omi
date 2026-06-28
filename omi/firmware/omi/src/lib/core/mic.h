#ifndef MIC_H
#define MIC_H

#include <stdbool.h>
#include <stdint.h>

typedef void (*mix_handler)(int16_t *);

/**
 * @brief Initialize the Microphone
 *
 * Initializes the Microphone
 *
 * @return 0 if successful, negative errno code if error
 */
int mic_start();
void set_mic_callback(mix_handler _callback);

void mic_off();
void mic_on();
void mic_set_gain(uint8_t gain_level);

/** Pause/resume the DMIC stream WITHOUT powering the mic down — used for mute
 *  (the audio characteristic goes silent but the mic stays initialized so
 *  unmute is instant). */
void mic_pause();
void mic_resume();
bool mic_is_running();
#endif
