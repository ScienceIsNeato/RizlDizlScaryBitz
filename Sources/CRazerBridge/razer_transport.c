/*
 * razer_transport.c — original USB transport for Razer keyboards on macOS.
 *
 * Implements the Razer HID "extended matrix" lighting protocol from the wire
 * specification (packet layout, checksum, command identifiers) using Apple's
 * IOKit USB device API. No third-party driver code is used.
 *
 * The protocol details encoded here (90-byte report format, the XOR checksum,
 * command class 0x0F with effect/frame command ids, the Ornata transaction id
 * and report index) are interface facts about how the hardware is addressed.
 */

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#include "razer_bridge.h"

/* ── Hardware constants ─────────────────────────────── */

#define RZ_VENDOR_ID     0x1532
#define RZ_ORNATA_V2_PID 0x025D

#define RZ_REPORT_LEN    90      /* every report is exactly 90 bytes        */
#define RZ_REPORT_INDEX  0x02    /* wIndex: the lighting-control interface   */
#define RZ_REPORT_VALUE  0x0300  /* wValue: HID feature report, report id 0  */
#define RZ_TXN_ID        0x1F    /* transaction id used by the Ornata family */

/* HID class control-request opcodes / direction bytes */
#define RZ_HID_GET_REPORT 0x01
#define RZ_HID_SET_REPORT 0x09
#define RZ_BM_OUT 0x21   /* host->device | class | interface */
#define RZ_BM_IN  0xA1   /* device->host | class | interface */

/* Command classes / ids */
#define RZ_CLASS_MATRIX     0x0F
#define RZ_CMD_EFFECT       0x02
#define RZ_CMD_SET_FRAME    0x03

/* Effect ids */
#define RZ_EFFECT_CUSTOM    0x08
#define RZ_EFFECT_STATIC    0x01
#define RZ_EFFECT_SPECTRUM  0x03

/* Storage / LED selectors */
#define RZ_VARSTORE       0x01
#define RZ_BACKLIGHT_LED  0x05

/* Device reply status codes */
#define RZ_STATUS_BUSY          0x01
#define RZ_STATUS_OK            0x02
#define RZ_STATUS_FAIL          0x03
#define RZ_STATUS_TIMEOUT       0x04
#define RZ_STATUS_UNSUPPORTED   0x05

/* The fixed 90-byte report. remaining_packets stays 0 for single-packet
   commands, so its byte order never matters in practice. */
#pragma pack(push, 1)
typedef struct {
    uint8_t  status;
    uint8_t  transaction_id;
    uint16_t remaining_packets;
    uint8_t  protocol_type;
    uint8_t  data_size;
    uint8_t  command_class;
    uint8_t  command_id;
    uint8_t  arguments[80];
    uint8_t  crc;
    uint8_t  reserved;
} RazerPacket;
#pragma pack(pop)

_Static_assert(sizeof(RazerPacket) == RZ_REPORT_LEN, "report must be 90 bytes");

/* ── State ──────────────────────────────────────────── */

static IOUSBDeviceInterface **g_dev = NULL;
static IOReturn g_last_io = kIOReturnSuccess;

#define RZ_RETRIES 3
static const useconds_t k_retry_delay_us[RZ_RETRIES] = { 1000, 5000, 25000 };
#define RZ_SETTLE_US 600   /* device needs a beat between set and get */

static const char *io_name(IOReturn r) {
    switch (r) {
    case kIOReturnSuccess:         return "Success";
    case kIOReturnNoDevice:        return "NoDevice (disconnected)";
    case kIOReturnNotOpen:         return "NotOpen";
    case kIOReturnExclusiveAccess: return "ExclusiveAccess";
    case kIOReturnNotResponding:   return "NotResponding";
    case kIOReturnAborted:         return "Aborted";
    case kIOReturnBadArgument:     return "BadArgument";
    default:                       return "Unknown";
    }
}

/* ── Packet helpers ─────────────────────────────────── */

static uint8_t packet_checksum(const RazerPacket *p) {
    const uint8_t *raw = (const uint8_t *)p;
    uint8_t x = 0;
    for (int i = 2; i < 88; i++) x ^= raw[i];
    return x;
}

/* An effect command: class 0x0F / id 0x02, addressing (store, led, effect). */
static RazerPacket effect_packet(uint8_t data_size, uint8_t store,
                                 uint8_t led, uint8_t effect) {
    RazerPacket p;
    memset(&p, 0, sizeof(p));
    p.transaction_id = RZ_TXN_ID;
    p.data_size      = data_size;
    p.command_class  = RZ_CLASS_MATRIX;
    p.command_id     = RZ_CMD_EFFECT;
    p.arguments[0]   = store;
    p.arguments[1]   = led;
    p.arguments[2]   = effect;
    return p;
}

/* ── USB round trip ─────────────────────────────────── */

static IOReturn control_out(const RazerPacket *p) {
    IOUSBDevRequest r;
    r.bmRequestType = RZ_BM_OUT;
    r.bRequest      = RZ_HID_SET_REPORT;
    r.wValue        = RZ_REPORT_VALUE;
    r.wIndex        = RZ_REPORT_INDEX;
    r.wLength       = RZ_REPORT_LEN;
    r.pData         = (void *)p;
    return (*g_dev)->DeviceRequest(g_dev, &r);
}

static IOReturn control_in(RazerPacket *out) {
    IOUSBDevRequest r;
    r.bmRequestType = RZ_BM_IN;
    r.bRequest      = RZ_HID_GET_REPORT;
    r.wValue        = RZ_REPORT_VALUE;
    r.wIndex        = RZ_REPORT_INDEX;
    r.wLength       = RZ_REPORT_LEN;
    r.pData         = out;
    return (*g_dev)->DeviceRequest(g_dev, &r);
}

/* Send a command, read the reply, retrying transient errors / busy. */
static int send_packet(RazerPacket *cmd) {
    if (!g_dev) return -1;
    cmd->crc = packet_checksum(cmd);

    for (int attempt = 0; attempt <= RZ_RETRIES; attempt++) {
        IOReturn rc = control_out(cmd);
        if (rc != kIOReturnSuccess) {
            g_last_io = rc;
            if (attempt < RZ_RETRIES) { usleep(k_retry_delay_us[attempt]); continue; }
            return -2;
        }

        usleep(RZ_SETTLE_US);

        RazerPacket reply;
        memset(&reply, 0, sizeof(reply));
        rc = control_in(&reply);
        if (rc != kIOReturnSuccess) {
            g_last_io = rc;
            if (attempt < RZ_RETRIES) { usleep(k_retry_delay_us[attempt]); continue; }
            return -2;
        }

        /* Reply should echo the command we sent. */
        if (reply.command_class != cmd->command_class ||
            reply.command_id    != cmd->command_id)
            return -3;

        if (reply.status == RZ_STATUS_BUSY) {
            if (attempt < RZ_RETRIES) { usleep(k_retry_delay_us[attempt]); continue; }
            return -3;
        }
        if (reply.status == RZ_STATUS_FAIL ||
            reply.status == RZ_STATUS_TIMEOUT ||
            reply.status == RZ_STATUS_UNSUPPORTED)
            return -3;

        return 0;
    }
    return -2;
}

/* ── Device discovery / open ────────────────────────── */

/* Open the first connected Razer keyboard we support, returning an opened
   device interface. Standard IOKit USB-device plug-in boilerplate. */
static IOUSBDeviceInterface **open_keyboard(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return NULL;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != kIOReturnSuccess)
        return NULL;

    IOUSBDeviceInterface **found = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) && !found) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kern_return_t kr = IOCreatePlugInInterfaceForService(
            service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
            &plugin, &score);
        IOObjectRelease(service);
        if (kr != kIOReturnSuccess || !plugin) continue;

        IOUSBDeviceInterface **dev = NULL;
        HRESULT hr = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
        (*plugin)->Release(plugin);
        if (hr || !dev) continue;

        UInt16 vid = 0, pid = 0;
        (*dev)->GetDeviceVendor(dev, &vid);
        (*dev)->GetDeviceProduct(dev, &pid);
        if (vid != RZ_VENDOR_ID || pid != RZ_ORNATA_V2_PID) {
            (*dev)->Release(dev);
            continue;
        }

        if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) {
            (*dev)->Release(dev);
            continue;
        }
        found = dev;
    }
    while ((service = IOIteratorNext(iter))) IOObjectRelease(service);
    IOObjectRelease(iter);
    return found;
}

int bridge_open(void) {
    if (g_dev) return 0;
    g_dev = open_keyboard();
    return g_dev ? 0 : -1;
}

void bridge_close(void) {
    if (g_dev) {
        (*g_dev)->USBDeviceClose(g_dev);
        (*g_dev)->Release(g_dev);
        g_dev = NULL;
    }
}

int bridge_reconnect(void) {
    bridge_close();
    return bridge_open();
}

int bridge_last_error(void) { return (int)g_last_io; }
const char *bridge_last_error_str(void) { return io_name(g_last_io); }

/* ── Lighting commands ──────────────────────────────── */

int bridge_set_custom_mode(void) {
    RazerPacket p = effect_packet(0x0C, 0x00, 0x00, RZ_EFFECT_CUSTOM);
    return send_packet(&p);
}

int bridge_set_spectrum(void) {
    RazerPacket p = effect_packet(0x06, RZ_VARSTORE, RZ_BACKLIGHT_LED, RZ_EFFECT_SPECTRUM);
    return send_packet(&p);
}

int bridge_set_static(unsigned char r, unsigned char g, unsigned char b) {
    RazerPacket p = effect_packet(0x09, RZ_VARSTORE, RZ_BACKLIGHT_LED, RZ_EFFECT_STATIC);
    p.arguments[5] = 0x01;
    p.arguments[6] = r;
    p.arguments[7] = g;
    p.arguments[8] = b;
    return send_packet(&p);
}

/* buf is a sequence of rows: [row, start_col, stop_col, R,G,B, R,G,B, ...]. */
int bridge_set_custom_frame(const unsigned char *buf, int len) {
    if (!g_dev) return -1;

    int offset = 0;
    int last_err = 0;
    while (offset < len) {
        if (offset + 3 > len) return -3;

        unsigned char row   = buf[offset++];
        unsigned char start = buf[offset++];
        unsigned char stop  = buf[offset++];
        if (start > stop) return -3;

        int rgb_len = (stop - start + 1) * 3;
        if (offset + rgb_len > len) return -3;

        RazerPacket p;
        memset(&p, 0, sizeof(p));
        p.transaction_id = RZ_TXN_ID;
        p.data_size      = 0x47;            /* fixed payload length the device expects */
        p.command_class  = RZ_CLASS_MATRIX;
        p.command_id     = RZ_CMD_SET_FRAME;
        p.arguments[2]   = row;
        p.arguments[3]   = start;
        p.arguments[4]   = stop;
        memcpy(&p.arguments[5], &buf[offset], (size_t)rgb_len);

        int rc = send_packet(&p);
        if (rc != 0) last_err = rc;

        offset += rgb_len;
    }
    return last_err;
}

/* ── Device enumeration (read-only; safe while the device is open) ───────── */

static const char *pid_name(uint16_t pid) {
    switch (pid) {
    case 0x025D: return "Ornata Chroma V2";
    case 0x021E: return "Ornata Chroma";
    case 0x021F: return "Ornata";
    case 0x025E: return "Cynosa V2";
    case 0x026B: return "Huntsman V2";
    case 0x024E: return "BlackWidow V3";
    default:     return NULL;
    }
}

int bridge_list_devices(BridgeDeviceInfo *out, int max_count) {
    /* Read product ids straight from the IOKit registry without opening the
       device, so this works even while the engine holds it open. The matching
       dictionary's idVendor filter is unreliable on macOS 15+, so we filter
       in code. */
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return 0;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != kIOReturnSuccess)
        return 0;

    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        if (count >= max_count) { IOObjectRelease(service); continue; }

        CFNumberRef vidRef = IORegistryEntryCreateCFProperty(
            service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        int vid = 0;
        if (vidRef) { CFNumberGetValue(vidRef, kCFNumberIntType, &vid); CFRelease(vidRef); }
        if (vid != RZ_VENDOR_ID) { IOObjectRelease(service); continue; }

        CFNumberRef pidRef = IORegistryEntryCreateCFProperty(
            service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        if (pidRef) {
            int pid = 0;
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
            CFRelease(pidRef);

            const char *name = pid_name((uint16_t)pid);
            out[count].product_id = (uint16_t)pid;
            if (name) snprintf(out[count].name, sizeof(out[count].name), "%s", name);
            else      snprintf(out[count].name, sizeof(out[count].name), "Razer Device 0x%04X", pid);
            count++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return count;
}
