#ifndef razer_bridge_h
#define razer_bridge_h

#include <stdint.h>

int bridge_open(void);
void bridge_close(void);
int bridge_reconnect(void);
int bridge_last_error(void);
const char *bridge_last_error_str(void);
int bridge_set_custom_mode(void);
int bridge_set_custom_frame(const unsigned char *buf, int len);
int bridge_set_spectrum(void);
int bridge_set_static(unsigned char r, unsigned char g, unsigned char b);

/* Device enumeration — writes into caller-provided buffer, no cleanup needed */
typedef struct {
    uint16_t product_id;
    char name[64];
} BridgeDeviceInfo;

int bridge_list_devices(BridgeDeviceInfo *out, int max_count);

#endif
