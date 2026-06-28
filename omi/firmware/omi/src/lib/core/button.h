#ifndef BUTTON_H
#define BUTTON_H

#include <zephyr/input/input.h>
#include <zephyr/kernel.h>

typedef enum { IDLE, GRACE } FSM_STATE_T;

int button_init();
void activate_button_work();
void register_button_service();
void turnoff_all();
/** True while the mic is muted via the Device Command (0x03). The LED state
 *  loop reads this to show a "muted" color that survives its 1Hz refresh. */
bool is_muted(void);
FSM_STATE_T get_current_button_state();

void force_button_state(FSM_STATE_T state);

// Input message queue from evt/button.c
extern struct k_msgq input_button;

#endif
