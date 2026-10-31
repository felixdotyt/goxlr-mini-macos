// Phase 4 step 1 matching spike (ADR 0004 option (B)). See MatchSpike.iig.

#include <os/log.h>

#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/OSSharedPtr.h>
#include <USBDriverKit/IOUSBHostDevice.h>

#include "MatchSpike.h"

namespace {
// DCP global data (SPEC.md §2, L-114): vendor IN to interface 0, 24 bytes.
constexpr uint8_t kGlobalDataRequestType = 0xC1;
constexpr uint8_t kGlobalDataRequest = 0;
constexpr uint16_t kGlobalDataLength = 24;
constexpr uint32_t kRequestTimeoutMs = 200;
constexpr uint32_t kMagic0 = 0x04061973, kMagic1 = 0x18101966;
constexpr uint8_t kConfiguration = 1;
constexpr uint64_t kPollIntervalMs = 2000;
constexpr uint64_t kMaxPolls = 900; // 30 minutes
}

struct MatchSpike_IVars {
    OSSharedPtr<IOUSBHostDevice> device;
    OSSharedPtr<IOBufferMemoryDescriptor> buffer;
    OSSharedPtr<IODispatchQueue> queue;
    OSSharedPtr<IOTimerDispatchSource> timer;
    OSSharedPtr<OSAction> timerAction;
    mach_timebase_info_data_t timebase;
    bool opened;
    uint64_t polls;
    uint64_t failures;
};

// One global-data read, logged with its result, length and decoded words.
static kern_return_t readGlobalData(MatchSpike * client, MatchSpike_IVars * ivars, uint64_t index)
{
    uint16_t done = 0;
    uint64_t start = mach_absolute_time();
    kern_return_t ret = ivars->device->DeviceRequest(client, kGlobalDataRequestType, kGlobalDataRequest, 0, 0,
                                                     kGlobalDataLength, ivars->buffer.get(), &done,
                                                     kRequestTimeoutMs);
    uint64_t us = (mach_absolute_time() - start) * ivars->timebase.numer / ivars->timebase.denom / 1000;
    IOAddressSegment range = {};
    ivars->buffer->GetAddressRange(&range);
    const uint32_t * words = reinterpret_cast<const uint32_t *>(range.address);
    bool magic = ret == kIOReturnSuccess && done == kGlobalDataLength && words[0] == kMagic0 && words[1] == kMagic1;
    os_log(OS_LOG_DEFAULT,
           "XLRMatch: global data %llu -> 0x%x, %u bytes, %llu us, magic %{public}s, dcp_version %u, max_payload %u",
           index, ret, done, us, magic ? "ok" : "BAD", done >= 12 ? words[2] : 0, done >= 20 ? words[4] : 0);
    return magic ? kIOReturnSuccess : (ret != kIOReturnSuccess ? ret : kIOReturnIOError);
}

bool MatchSpike::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(MatchSpike_IVars, 1);
    return ivars != nullptr;
}

void MatchSpike::free()
{
    if (ivars) {
        ivars->timerAction.reset();
        ivars->timer.reset();
        ivars->queue.reset();
        ivars->buffer.reset();
        ivars->device.reset();
    }
    IOSafeDeleteNULL(ivars, MatchSpike_IVars, 1);
    super::free();
}

kern_return_t
IMPL(MatchSpike, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "XLRMatch: Start super 0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;
    mach_timebase_info(&ivars->timebase);

    IOUSBHostDevice * device = OSDynamicCast(IOUSBHostDevice, provider);
    if (!device) {
        os_log(OS_LOG_DEFAULT, "XLRMatch: provider is not an IOUSBHostDevice");
        return kIOReturnNoDevice;
    }
    ivars->device.reset(device, OSRetain);

    ret = device->Open(this, 0, 0);
    os_log(OS_LOG_DEFAULT, "XLRMatch: step 1 Open 0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;
    ivars->opened = true;

    ret = device->SetConfiguration(kConfiguration, true);
    os_log(OS_LOG_DEFAULT, "XLRMatch: step 2 SetConfiguration(%u, matchInterfaces) 0x%x", kConfiguration, ret);
    if (ret != kIOReturnSuccess) return ret;

    IOBufferMemoryDescriptor * buffer = nullptr;
    ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionIn, kGlobalDataLength, 0, &buffer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->buffer = OSSharedPtr(buffer, OSNoRetain);
    // A failed read is reported, not fatal: the spike's question is whether it works.
    readGlobalData(this, ivars, 0);

    IODispatchQueue * queue = nullptr;
    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &queue);
    if (ret != kIOReturnSuccess) return ret;
    ivars->queue = OSSharedPtr(queue, OSNoRetain);
    IOTimerDispatchSource * timer = nullptr;
    ret = IOTimerDispatchSource::Create(queue, &timer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timer = OSSharedPtr(timer, OSNoRetain);
    OSAction * action = nullptr;
    ret = CreateActionPollTimerFired(0, &action);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timerAction = OSSharedPtr(action, OSNoRetain);
    ret = timer->SetHandler(action);
    if (ret != kIOReturnSuccess) return ret;
    uint64_t interval = kPollIntervalMs * 1000000 * ivars->timebase.denom / ivars->timebase.numer;
    ret = timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + interval, 0);
    os_log(OS_LOG_DEFAULT, "XLRMatch: polling every %llu ms, at most %llu reads, 0x%x", kPollIntervalMs, kMaxPolls,
           ret);
    return ret;
}

kern_return_t
IMPL(MatchSpike, Stop)
{
    os_log(OS_LOG_DEFAULT, "XLRMatch: Stop after %llu polls, %llu failed", ivars->polls, ivars->failures);
    auto finish = ^{
        if (ivars->opened) {
            kern_return_t closed = ivars->device->Close(this, 0);
            os_log(OS_LOG_DEFAULT, "XLRMatch: Close 0x%x", closed);
            ivars->opened = false;
        }
        Stop(provider, SUPERDISPATCH);
    };
    // As in ControlSpike (ADR 0003 finding 15): finish only after the timer's
    // cancel handler has run.
    if (ivars->timer) ivars->timer->Cancel(finish);
    else finish();
    return kIOReturnSuccess;
}

void
IMPL(MatchSpike, PollTimerFired)
{
    if (ivars->polls >= kMaxPolls) return;
    ivars->polls++;
    if (readGlobalData(this, ivars, ivars->polls) != kIOReturnSuccess) ivars->failures++;
    if (ivars->polls < kMaxPolls) {
        uint64_t interval = kPollIntervalMs * 1000000 * ivars->timebase.denom / ivars->timebase.numer;
        ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, time + interval, 0);
    }
}
