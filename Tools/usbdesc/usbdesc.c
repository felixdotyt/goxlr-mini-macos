// usbdesc: read-only USB descriptor dump for a GoXLR / GoXLR Mini (PROMPT.md Phase 2).
//
// Never opens the device and sends only standard GET_DESCRIPTOR IN requests;
// see send_get_descriptor(). The configuration descriptor comes from the
// cache that IOUSBLib keeps, so it causes no bus traffic.
//
// Output (stdout), one record per line:
//   device <hex>          device descriptor (GET_DESCRIPTOR, 18 bytes)
//   config <hex>          configuration descriptor 0 (cached copy)
//   string <idx> <hex>    string descriptor <idx>, language 0x0409
//
// Usage: usbdesc [string-index ...]

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>

enum { kVendorTCHelicon = 0x1220, kProductGoXLR = 0x8FE0, kProductGoXLRMini = 0x8FE4 };

static void print_hex(const char *label, int index, const UInt8 *bytes, UInt32 length) {
    if (index >= 0) printf("%s %d ", label, index);
    else printf("%s ", label);
    for (UInt32 i = 0; i < length; i++) printf("%02x", bytes[i]);
    printf("\n");
}

// The only request this tool sends: standard, device-to-host, GET_DESCRIPTOR.
static IOReturn send_get_descriptor(IOUSBDeviceInterface650 **dev, UInt8 type, UInt8 index,
                                    UInt16 language, UInt8 *buffer, UInt16 length, UInt32 *done) {
    IOUSBDevRequest req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor,
        .wValue = (UInt16)((type << 8) | index),
        .wIndex = language,
        .wLength = length,
        .pData = buffer,
    };
    IOReturn kr = (*dev)->DeviceRequest(dev, &req);
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

int main(int argc, char **argv) {
    io_service_t service = find_device();
    if (!service) {
        fprintf(stderr, "usbdesc: no GoXLR (1220:8fe0) or GoXLR Mini (1220:8fe4) found\n");
        return 1;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plugin) {
        fprintf(stderr, "usbdesc: IOCreatePlugInInterfaceForService failed: 0x%08x\n", kr);
        return 1;
    }
    IOUSBDeviceInterface650 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (hr || !dev) {
        fprintf(stderr, "usbdesc: QueryInterface failed: 0x%08x\n", (unsigned)hr);
        return 1;
    }

    int status = 0;
    UInt8 buffer[255];
    UInt32 done = 0;

    kr = send_get_descriptor(dev, kUSBDeviceDesc, 0, 0, buffer, 18, &done);
    if (kr == kIOReturnSuccess) print_hex("device", -1, buffer, done);
    else { fprintf(stderr, "usbdesc: device descriptor: 0x%08x\n", kr); status = 1; }

    IOUSBConfigurationDescriptorPtr config = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &config);
    if (kr == kIOReturnSuccess && config) print_hex("config", -1, (const UInt8 *)config, USBToHostWord(config->wTotalLength));
    else { fprintf(stderr, "usbdesc: config descriptor: 0x%08x\n", kr); status = 1; }

    for (int i = 1; i < argc; i++) {
        long index = strtol(argv[i], NULL, 0);
        if (index < 1 || index > 255) { fprintf(stderr, "usbdesc: bad string index %s\n", argv[i]); status = 1; continue; }
        kr = send_get_descriptor(dev, kUSBStringDesc, (UInt8)index, 0x0409, buffer, sizeof buffer, &done);
        if (kr == kIOReturnSuccess) print_hex("string", (int)index, buffer, done);
        else { fprintf(stderr, "usbdesc: string %ld: 0x%08x\n", index, kr); status = 1; }
    }

    (*dev)->Release(dev);
    return status;
}
