// dcpglobal: read the DCP global data from a GoXLR / GoXLR Mini (SPEC.md §1–2, LEDGER L-090).
//
// Sends exactly one request, and only with --send: vendor IN to interface 0,
// bRequest 0, wValue 0, wIndex 0, wLength 24, 200 ms timeout. Never opens the
// device. goxlr-utility says this read "also initialises audio" (L-055), so
// run it only in a supervised hardware session.
//
// Output (stdout):
//   time <HH:MM:SS.mmm>   when the request was sent
//   result <IOReturn>     and, on success:
//   global <hex>          the reply bytes
//   magic <ok|bad> dcp_version <n> max_payload <n> word3 <hex> word5 <hex>
//
// Usage: dcpglobal --send

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

enum { kVendorTCHelicon = 0x1220, kProductGoXLR = 0x8FE0, kProductGoXLRMini = 0x8FE4 };
enum { kGlobalDataLength = 24, kTimeoutMs = 200 };

// The only request this tool sends.
static IOReturn read_global_data(IOUSBDeviceInterface650 **dev, UInt8 *buffer, UInt32 *done) {
    IOUSBDevRequestTO req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBInterface),
        .bRequest = 0,
        .wValue = 0,
        .wIndex = 0,
        .wLength = kGlobalDataLength,
        .pData = buffer,
        .noDataTimeout = kTimeoutMs,
        .completionTimeout = kTimeoutMs,
    };
    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    *done = req.wLenDone;
    return kr;
}

static io_service_t find_device(void) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS)
        return IO_OBJECT_NULL;
    io_service_t found = IO_OBJECT_NULL, service;
    while ((service = IOIteratorNext(it))) {
        int vid = 0, pid = 0;
        CFNumberRef v = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFNumberRef p = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        if (v) { CFNumberGetValue(v, kCFNumberIntType, &vid); CFRelease(v); }
        if (p) { CFNumberGetValue(p, kCFNumberIntType, &pid); CFRelease(p); }
        if (!found && vid == kVendorTCHelicon && (pid == kProductGoXLR || pid == kProductGoXLRMini)) {
            found = service;
            continue;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return found;
}

static UInt32 word(const UInt8 *b, int i) {
    return (UInt32)b[4 * i] | (UInt32)b[4 * i + 1] << 8 | (UInt32)b[4 * i + 2] << 16 | (UInt32)b[4 * i + 3] << 24;
}

static void print_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    printf("time %02d:%02d:%02d.%03d\n", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--send") != 0) {
        fprintf(stderr, "usage: dcpglobal --send   (sends one vendor IN request: c1 00 0000 0000 1800)\n");
        return 2;
    }
    io_service_t service = find_device();
    if (!service) {
        fprintf(stderr, "dcpglobal: no GoXLR (1220:8fe0) or GoXLR Mini (1220:8fe4) found\n");
        return 1;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plugin) {
        fprintf(stderr, "dcpglobal: IOCreatePlugInInterfaceForService failed: 0x%08x\n", kr);
        return 1;
    }
    IOUSBDeviceInterface650 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (hr || !dev) {
        fprintf(stderr, "dcpglobal: QueryInterface failed: 0x%08x\n", (unsigned)hr);
        return 1;
    }

    UInt8 buffer[kGlobalDataLength] = {0};
    UInt32 done = 0;
    print_time();
    kr = read_global_data(dev, buffer, &done);
    printf("result 0x%08x length %u\n", kr, (unsigned)done);
    if (kr == kIOReturnSuccess) {
        printf("global ");
        for (UInt32 i = 0; i < done; i++) printf("%02x", buffer[i]);
        printf("\n");
        if (done == kGlobalDataLength) {
            int magic = word(buffer, 0) == 0x04061973 && word(buffer, 1) == 0x18101966;
            printf("magic %s dcp_version %u max_payload %u word3 0x%08x word5 0x%08x\n", magic ? "ok" : "bad",
                   word(buffer, 2), word(buffer, 4), word(buffer, 3), word(buffer, 5));
        }
    }

    (*dev)->Release(dev);
    return kr == kIOReturnSuccess ? 0 : 1;
}
