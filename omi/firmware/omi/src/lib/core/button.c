#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/input/input.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/poweroff.h>

#include "haptic.h"
#include "led.h"
#include "mic.h"
#include "speaker.h"
#include "transport.h"
#include "wdog_facade.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

#include "imu.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sd_card.h"
#endif

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset);

static void gesture_ccc_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t gesture_config_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                    const void *buf, uint16_t len, uint16_t offset, uint8_t flags);
static ssize_t gesture_command_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                     const void *buf, uint16_t len, uint16_t offset, uint8_t flags);

static struct bt_uuid_128 button_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7924, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 button_characteristic_data_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7925, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
// Gesture service chars (reconstructed to match the app + engineer DFU):
//   23BA7926 gesture token (NOTIFY), 23BA7927 config (WRITE), 23BA7928 command (WRITE)
static struct bt_uuid_128 gesture_event_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7926, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 gesture_config_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7927, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 gesture_command_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7928, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));

static struct bt_gatt_attr button_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&button_uuid),
    // [1/2] 23BA7925 Button State — READ + NOTIFY (press/release/tap)
    BT_GATT_CHARACTERISTIC(&button_characteristic_data_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           button_data_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(button_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    // [3/4] 23BA7926 Gesture Token — NOTIFY ([0x10, count, clicks...])
    BT_GATT_CHARACTERISTIC(&gesture_event_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_NONE,
                           NULL,
                           NULL,
                           NULL),
    BT_GATT_CCC(gesture_ccc_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    // [5] 23BA7927 Config — WRITE (3× uint16 LE: short_max, inter_click, power_hold)
    BT_GATT_CHARACTERISTIC(&gesture_config_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           gesture_config_write,
                           NULL),
    // [6] 23BA7928 Command — WRITE (0x01 haptic / 0x02 led / 0x03 mute / 0x04 power)
    BT_GATT_CHARACTERISTIC(&gesture_command_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           gesture_command_write,
                           NULL),
};

static struct bt_gatt_service button_service = BT_GATT_SERVICE(button_service_attr);

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}
static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

static bool was_pressed = false;

// Using GPIO callback due to the lower priority of the input subsystem vs. storage.c's thread that prevents the
// callback from working properly.
#define BUTTON_CHECK_INTERVAL 40 // 0.04 seconds, 25 Hz

void check_button_level(struct k_work *work_item);

// Dedicated work-queue for button polling. Previously button_work ran on the
// SHARED system workqueue, which storage.c also uses — and a long, cooperative
// SD-card storage work item would run to completion without yielding, starving
// the 25 Hz button poll so presses were silently missed (the device appeared to
// "stop sending button events"). Giving the button its own thread (higher
// cooperative priority than storage) guarantees the poll keeps running
// regardless of storage load, with or without offline storage enabled.
#define BUTTON_WORKQ_STACK_SIZE 1024
#define BUTTON_WORKQ_PRIORITY   K_PRIO_COOP(2) // above the system workqueue / storage
K_THREAD_STACK_DEFINE(button_workq_stack, BUTTON_WORKQ_STACK_SIZE);
static struct k_work_q button_workq;
static bool button_workq_started = false;

K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

#define DEFAULT_STATE 0
#define SINGLE_TAP 1
#define DOUBLE_TAP 2
#define LONG_TAP 3
#define BUTTON_PRESS 4
#define BUTTON_RELEASE 5

// 4 is button down, 5 is button up
static FSM_STATE_T current_button_state = IDLE;
static uint32_t inc_count_1 = 0;
static uint32_t inc_count_0 = 0;

static int final_button_state[2] = {0, 0};
const static int threshold = 10;

static void reset_count()
{
    inc_count_0 = 0;
    inc_count_1 = 0;
}
static inline void notify_press()
{
    final_button_state[0] = BUTTON_PRESS;
    LOG_INF("Button pressed");
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

static inline void notify_unpress()
{
    final_button_state[0] = BUTTON_RELEASE;
    LOG_INF("Button released");
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

static inline void notify_tap()
{
    final_button_state[0] = SINGLE_TAP;
    LOG_INF("Button single tap");
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

static inline void notify_double_tap()
{
    final_button_state[0] = DOUBLE_TAP; // button press
    LOG_INF("Button double tap");
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

static inline void notify_long_tap()
{
    final_button_state[0] = LONG_TAP; // button press
    LOG_INF("Button long tap");
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

// ── Gesture token (23BA7926) + config (23BA7927) + command (23BA7928) ───────

#define GESTURE_TOKEN_VERSION 0x10
#define GESTURE_MAX_CLICKS 8

// Configurable thresholds (RAM only — no NVS; the app re-sends every connect).
// Defaults match the firmware spec (600 / 800 / 10000).
static uint16_t cfg_short_max_ms = 600;    // click < this = SHORT, >= and < power = LONG
static uint16_t cfg_inter_click_ms = 800;  // silence that closes a click sequence
static uint16_t cfg_power_hold_ms = 10000; // hold >= this = local power off

// In-progress click sequence (each entry 0=SHORT, 1=LONG).
static uint8_t gesture_clicks[GESTURE_MAX_CLICKS];
static uint8_t gesture_click_count = 0;

static void gesture_ccc_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for gesture tokens");
    }
}

// Power-off must run OFF the button-poll context (turnoff_all does ~4s of
// blocking teardown). A dedicated work item on the system workqueue gives it a
// clean thread that runs to completion + sys_poweroff(). Used by the 5-tap
// gesture and the 0x04 Device Command.
static void poweroff_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    turnoff_all();
}
static K_WORK_DEFINE(poweroff_work, poweroff_work_handler);

// Emit one completed gesture sequence as [0x10, count, click0, click1, ...].
static void notify_gesture_token(void)
{
    if (gesture_click_count == 0 || gesture_click_count > GESTURE_MAX_CLICKS) {
        return;
    }
    uint8_t payload[2 + GESTURE_MAX_CLICKS];
    payload[0] = GESTURE_TOKEN_VERSION;
    payload[1] = gesture_click_count;
    for (uint8_t i = 0; i < gesture_click_count; i++) {
        payload[2 + i] = gesture_clicks[i] ? 1 : 0;
    }
    LOG_INF("Gesture token: %u clicks", gesture_click_count);
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        // Find the 23BA7926 attribute by UUID rather than a hardcoded index —
        // a wrong index silently no-ops the notify (the taps-stopped bug). This
        // matches whatever offset the macro expansion produced.
        bt_gatt_notify_uuid(conn, &gesture_event_uuid.uuid, button_service.attrs, payload,
                            2 + gesture_click_count);
    }
}

// True when a completed sequence is exactly N short clicks (e.g. 5-tap = power off).
static bool gesture_is_n_short(uint8_t n)
{
    if (gesture_click_count != n) {
        return false;
    }
    for (uint8_t i = 0; i < n; i++) {
        if (gesture_clicks[i] != 0) {
            return false;
        }
    }
    return true;
}

// Mute = pause the DMIC so the audio characteristic goes silent (mic stays
// initialized, so unmute is instant). Forward-declared bool defined with the
// command handler. Declared here so the command handler (below) can call it.
static bool s_muted;
static void gesture_set_mute(bool on)
{
    if (on == s_muted) {
        return;
    }
    s_muted = on;
    if (on) {
        mic_pause();
    } else {
        mic_resume();
    }
    LOG_INF("Mic %s", on ? "muted" : "unmuted");
}

#define BUTTON_PRESSED 1
#define BUTTON_RELEASED 0

#define TAP_THRESHOLD 300     // 300 ms for single tap
#define DOUBLE_TAP_WINDOW 600 // 600 ms maximum for double-tap
#define LONG_PRESS_TIME 3000  // (legacy; power-off now uses cfg_power_hold_ms)
#define GESTURE_POWEROFF_TAPS 5 // 5 short taps → power off

typedef enum {
    BUTTON_EVENT_NONE,
    BUTTON_EVENT_SINGLE_TAP,
    BUTTON_EVENT_DOUBLE_TAP,
    BUTTON_EVENT_LONG_PRESS,
    BUTTON_EVENT_RELEASE
} ButtonEvent;

static uint32_t current_time = 0;
static uint32_t btn_press_start_time;
static uint32_t btn_release_time;
static uint32_t btn_last_tap_time;
static bool btn_is_pressed;

static u_int8_t btn_last_event = BUTTON_EVENT_NONE;

void check_button_level(struct k_work *work_item)
{
    current_time = current_time + 1;

    u_int8_t btn_state = was_pressed ? BUTTON_PRESSED : BUTTON_RELEASED;

    ButtonEvent event = BUTTON_EVENT_NONE;

    // ── Gesture sequence accumulator (parallel to the legacy tap FSM) ───────
    // Independent of the button-state notifications below (which the app uses
    // for hold-to-talk). On each press→release we append one click (SHORT/LONG
    // by cfg_short_max_ms); after cfg_inter_click_ms of silence the sequence
    // completes → emit the 0x10 token and run 5-tap power-off. Uses its own ms
    // clock (gseq_*) so the legacy FSM's current_time resets don't disturb it.
    static bool gseq_prev_pressed = false;
    static uint32_t gseq_press_start_ms = 0;
    static uint32_t gseq_last_release_ms = 0;
    // Absolute monotonic ms — NOT derived from current_time, which the legacy
    // FSM resets to 0 on release (that would corrupt our inter-click deltas).
    uint32_t now_ms = (uint32_t)k_uptime_get();

    if (btn_state == BUTTON_PRESSED && !gseq_prev_pressed) {
        gseq_press_start_ms = now_ms;
    } else if (btn_state == BUTTON_RELEASED && gseq_prev_pressed) {
        uint32_t dur = now_ms - gseq_press_start_ms;
        // Ignore a hold long enough to be the power-hold (handled elsewhere).
        if (dur < cfg_power_hold_ms && gesture_click_count < GESTURE_MAX_CLICKS) {
            gesture_clicks[gesture_click_count++] = (dur >= cfg_short_max_ms) ? 1 : 0;
        }
        gseq_last_release_ms = now_ms;
    }
    gseq_prev_pressed = (btn_state == BUTTON_PRESSED);

    // Sequence completes after inter-click silence (and not while held).
    if (gesture_click_count > 0 && btn_state == BUTTON_RELEASED &&
        (now_ms - gseq_last_release_ms) >= cfg_inter_click_ms) {
        if (gesture_is_n_short(GESTURE_POWEROFF_TAPS)) {
            LOG_INF("5-tap -> power off");
            gesture_click_count = 0;
            // Defer to a dedicated work item: turnoff_all() does ~4s of blocking
            // k_msleep + transport/mic/watchdog teardown, which must NOT run on
            // the 25Hz button-poll context (it would starve the poll and can
            // wedge before sys_poweroff). Scheduling it onto the system workqueue
            // gives it a clean thread to run to completion + sys_poweroff().
            k_work_submit(&poweroff_work);
            return;
        }
        // Emit the token FIRST, then reset — notify_gesture_token() reads
        // gesture_click_count, so zeroing it before the notify (the v2 bug)
        // silently dropped every non-power-off token (taps stopped working).
        notify_gesture_token();
        gesture_click_count = 0;
    }

    // Debouncing pressed state
    if (btn_state == BUTTON_PRESSED && !btn_is_pressed) {
        btn_is_pressed = true;
        btn_press_start_time = current_time;
    } else if (btn_state == BUTTON_RELEASED && btn_is_pressed) {
        btn_is_pressed = false;
        btn_release_time = current_time;

        // Check for double tap
        uint32_t press_duration = (btn_release_time - btn_press_start_time) * BUTTON_CHECK_INTERVAL;
        if (press_duration < TAP_THRESHOLD) {
            if (btn_last_tap_time > 0 &&
                (current_time - btn_last_tap_time) * BUTTON_CHECK_INTERVAL < DOUBLE_TAP_WINDOW) {
                event = BUTTON_EVENT_DOUBLE_TAP;
                btn_last_tap_time = 0; // Reset double-tap / single-tap detection
            } else {
                btn_last_tap_time = current_time;
            }
        }
    }

    // Check for single tap
    if (btn_state == BUTTON_RELEASED && !btn_is_pressed) {
        uint32_t press_duration = (btn_release_time - btn_press_start_time) * BUTTON_CHECK_INTERVAL;
        if (press_duration < TAP_THRESHOLD && btn_last_tap_time > 0 &&
            (current_time - btn_press_start_time) * BUTTON_CHECK_INTERVAL > TAP_THRESHOLD) {
            event = BUTTON_EVENT_SINGLE_TAP;
            btn_last_tap_time = 0;
        } else if ((current_time - btn_press_start_time) * BUTTON_CHECK_INTERVAL > TAP_THRESHOLD) {
            event = BUTTON_EVENT_RELEASE;
        }
    }

    // Check for long press → power off. Uses the configurable power-hold
    // NOTE: long-press → power-off is INTENTIONALLY REMOVED. The app uses a held
    // button for press-and-hold-to-talk (hold while speaking), and a spoken
    // message can run long — a hold-based power-off would cut it off mid-sentence.
    // Power-off is now the 5-tap gesture (S,S,S,S,S) only, handled above.

    // Single tap
    if (event == BUTTON_EVENT_SINGLE_TAP) {
        LOG_INF("single tap detected\n");
        btn_last_event = event;

        notify_tap();
    }

    // Double tap
    if (event == BUTTON_EVENT_DOUBLE_TAP) {
        LOG_INF("double tap detected\n");
        btn_last_event = event;
        notify_double_tap();
    }

    // Releases, one time event
    if (event == BUTTON_EVENT_RELEASE && btn_last_event != BUTTON_EVENT_RELEASE) {
        LOG_PRINTK("release detected\n");
        btn_last_event = event;
        notify_unpress();

        // Reset
        current_time = 0;
        btn_press_start_time = 0;
        btn_release_time = 0;
        btn_last_tap_time = 0;
    }
    if (event == BUTTON_EVENT_RELEASE) {
        current_button_state = GRACE;
    }

    // Reschedule onto the dedicated button work-queue (never the shared system
    // one — see button_workq above) so storage can't starve the poll.
    k_work_reschedule_for_queue(&button_workq, &button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
    return 0;
}

static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    LOG_INF("button_data_read_characteristic");
    LOG_PRINTK("was_pressed: %d\n", final_button_state[0]);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &final_button_state, sizeof(final_button_state));
}

// 23BA7927 Config write: 6 bytes = 3× uint16 LE [short_max, inter_click, power_hold].
// Validation mirrors the spec: short_max in (0, power_hold). Held in RAM only.
static ssize_t gesture_config_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                    const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 6) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    const uint8_t *b = buf;
    uint16_t short_max = (uint16_t)(b[0] | (b[1] << 8));
    uint16_t inter_click = (uint16_t)(b[2] | (b[3] << 8));
    uint16_t power_hold = (uint16_t)(b[4] | (b[5] << 8));
    if (short_max == 0 || short_max >= power_hold) {
        LOG_WRN("Gesture config rejected: short_max=%u power_hold=%u", short_max, power_hold);
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }
    cfg_short_max_ms = short_max;
    cfg_inter_click_ms = inter_click;
    cfg_power_hold_ms = power_hold;
    LOG_INF("Gesture config: short=%u inter=%u power=%u", short_max, inter_click, power_hold);
    return len;
}

// 23BA7928 Command write: opcode + args.
//   0x01 HAPTIC : + uint16 LE duration ms
//   0x02 LED    : + R,G,B (0..100; we map >0 → channel on)
//   0x03 MUTE   : + mode (0 unmute / 1 mute / 2 toggle)
//   0x04 POWER  : power off the device (companion to the 5-tap gesture)
static ssize_t gesture_command_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                     const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    const uint8_t *b = buf;
    switch (b[0]) {
    case 0x01: { // HAPTIC
        if (len < 3) {
            return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
        }
        uint16_t ms = (uint16_t)(b[1] | (b[2] << 8));
#ifdef CONFIG_OMI_ENABLE_HAPTIC
        play_haptic_milli(ms);
#else
        ARG_UNUSED(ms);
#endif
        break;
    }
    case 0x02: { // LED r,g,b (0..100). Our driver is on/off per channel.
        if (len < 4) {
            return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
        }
        set_led_red(b[1] > 0);
        set_led_green(b[2] > 0);
        set_led_blue(b[3] > 0);
        break;
    }
    case 0x03: { // MUTE 0/1/2
        if (len < 2) {
            return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
        }
        bool want = (b[1] == 2) ? !s_muted : (b[1] == 1);
        gesture_set_mute(want);
        break;
    }
    case 0x04: // POWER OFF (deferred to the system workqueue, not this GATT context)
        LOG_INF("Power off via Device Command 0x04");
        k_work_submit(&poweroff_work);
        break;
    default:
        LOG_WRN("Unknown command opcode 0x%02x", b[0]);
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }
    return len;
}

static struct gpio_callback button_cb_data;

static void button_gpio_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    was_pressed = (gpio_pin_get_dt(&usr_btn) == 1);
    LOG_INF("Button %s (GPIO callback)", was_pressed ? "pressed" : "released");
}

int button_regist_callback()
{
    int ret;

    // Configure GPIO as input with pull-up
    ret = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (ret < 0) {
        LOG_ERR("Failed to configure button GPIO (%d)", ret);
        return ret;
    }

    // Setup interrupt on both edges
    ret = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_EDGE_BOTH);
    if (ret < 0) {
        LOG_ERR("Failed to configure button interrupt (%d)", ret);
        return ret;
    }

    // Register callback
    gpio_init_callback(&button_cb_data, button_gpio_callback, BIT(usr_btn.pin));
    gpio_add_callback(usr_btn.port, &button_cb_data);

    LOG_INF("Button initialized with GPIO interrupt");

    return 0;
}

int button_init()
{
    int ret;

    // Initialize the buttons device from evt
    if (!device_is_ready(buttons)) {
        LOG_ERR("Buttons device not ready");
        return -ENODEV;
    }

    // Enable runtime power management for the buttons device
    ret = pm_device_runtime_get(buttons);
    if (ret < 0) {
        LOG_ERR("Failed to enable buttons device (%d)", ret);
        return ret;
    }

    // Regist callback
    ret = button_regist_callback();
    if (ret < 0) {
        LOG_ERR("Failed to regist buttons callback (%d)", ret);
        return ret;
    }

    return 0;
}

void activate_button_work()
{
    // Start the dedicated button work-queue on first call (idempotent). Running
    // the poll on its OWN thread — not the shared system workqueue that storage.c
    // hogs — is the core fix for the button going silent under storage load.
    if (!button_workq_started) {
        k_work_queue_init(&button_workq);
        k_work_queue_start(&button_workq, button_workq_stack,
                           K_THREAD_STACK_SIZEOF(button_workq_stack),
                           BUTTON_WORKQ_PRIORITY, NULL);
        k_thread_name_set(&button_workq.thread, "button_workq");
        button_workq_started = true;
    }
    // Use reschedule (not schedule) so this is a safe, idempotent re-arm: if the
    // poll work item is somehow no longer pending, this revives it; if pending,
    // it's a no-op. Called at boot AND on every (re)connect.
    k_work_reschedule_for_queue(&button_workq, &button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
}

void register_button_service()
{
    bt_gatt_service_register(&button_service);
}

FSM_STATE_T get_current_button_state()
{
    return current_button_state;
}

void turnoff_all()
{
    int rc;

    // Immediate feedback: LED off and haptic
    led_off();
    // Set is_off immediately so set_led_state() keeps LEDs off
    is_off = true;

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    play_haptic_milli(100);
    k_msleep(300);
    haptic_off();
#endif

    // Delays for stability
    k_msleep(1000);

    // // Enter the low power mode
    transport_off();
    k_msleep(300);

    // Always turn off microphone
    mic_off();
    k_msleep(100);

    // Turn off speaker if enabled
#ifdef CONFIG_OMI_ENABLE_SPEAKER
    speaker_off();
    k_msleep(100);
#endif

    // Turn off accelerometer if enabled
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    accel_off();
    k_msleep(100);
#endif

    if (is_sd_on()) {
        app_sd_off();
    }
    k_msleep(300);

    // Put the buttons device to sleep if button is enabled
#ifdef CONFIG_OMI_ENABLE_BUTTON
    pm_device_runtime_put(buttons);
    k_msleep(100);
#endif

    // Disable USB if enabled
#ifdef CONFIG_OMI_ENABLE_USB
    NRF_USBD->INTENCLR = 0xFFFFFFFF;
#endif

    // Log system power off
    LOG_INF("System powering off");

    // Configure usr_btn as input with interrupt to allow wake-up
    rc = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO (%d)", rc);
        return;
    }

    rc = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_LEVEL_LOW);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO interrupt (%d)", rc);
        return;
    }
#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_turn_off();
#endif
    rc = watchdog_deinit();
    if (rc < 0) {
        LOG_ERR("Failed to deinitialize watchdog (%d)", rc);
        return;
    }

    
    /* Persist an IMU timestamp base so we can estimate time across system_off. */
    lsm6dsl_time_prepare_for_system_off();
    k_msleep(1000);
    LOG_INF("Entering system off; press usr_btn to restart");

    // Power off the system using sys_poweroff
    sys_poweroff();
}

void force_button_state(FSM_STATE_T state)
{
    current_button_state = state;
}
