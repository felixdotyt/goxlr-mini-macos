// usbreenum: make a GoXLR re-enumerate (detach and re-attach, no power cut)
// while no driver of ours holds it, for example to let a staged driver version
// match without unplugging. With the XLR driver attached, use
// `goxlrctl driver reset` instead: the driver's device session blocks this tool.
//
//   usbreenum [product-id-hex]     default 8fe4 (GoXLR Mini)
//
// Build: clang -O2 -Wall -o usbreenum usbreenum.c -framework IOKit -framework CoreFoundation

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    long product = argc > 1 ? strtol(argv[1], NULL, 16) : 0x8FE4;
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vendor = 0x1220, pid = (int)product;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor), p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) { fprintf(stderr, "usbreenum: no 1220:%04lx device\n", product); return 1; }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                        &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) { fprintf(stderr, "usbreenum: plug-in 0x%x\n", kr); return 1; }
    IOUSBDeviceInterface650 **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (!dev) { fprintf(stderr, "usbreenum: no device interface\n"); return 1; }

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "usbreenum: USBDeviceOpen 0x%x (a driver holds the device; with the XLR driver, use goxlrctl driver reset)\n", kr);
        (*dev)->Release(dev);
        return 1;
    }
    kr = (*dev)->USBDeviceReEnumerate(dev, 0);
    printf("USBDeviceReEnumerate -> 0x%x\n", kr);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return kr == kIOReturnSuccess ? 0 : 1;
}
