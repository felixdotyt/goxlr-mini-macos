// XLR driver user client. See XLRDriverUserClient.iig and XLRDriverABI.h.
// Any local process may open it (allow-any-userclient-access, ADR 0003), so
// it only forwards: the driver checks every command against the policy.

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSSharedPtr.h>

#include "XLRDriver.h"
#include "XLRDriverABI.h"
#include "XLRDriverUserClient.h"

struct XLRDriverUserClient_IVars {
    OSSharedPtr<XLRDriver> driver;
    bool attached;
    bool trusted; // signed by the driver's team: may send hardware-risk values
};

uint32_t gLiveClients;

bool XLRDriverUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(XLRDriverUserClient_IVars, 1);
    if (!ivars) return false;
    os_log(OS_LOG_DEFAULT, "XLRDriver: user client init (%u live)", __atomic_add_fetch(&gLiveClients, 1, __ATOMIC_RELAXED));
    return true;
}

void XLRDriverUserClient::free()
{
    os_log(OS_LOG_DEFAULT, "XLRDriver: user client free (%u live)", __atomic_sub_fetch(&gLiveClients, 1, __ATOMIC_RELAXED));
    if (ivars) ivars->driver.reset();
    IOSafeDeleteNULL(ivars, XLRDriverUserClient_IVars, 1);
    super::free();
}

kern_return_t
IMPL(XLRDriverUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    XLRDriver * driver = OSDynamicCast(XLRDriver, provider);
    if (!driver) return kIOReturnNoDevice;
    ivars->driver.reset(driver, OSRetain);
    OSDictionary * entitlements = nullptr;
    if (CopyClientEntitlements(&entitlements) == kIOReturnSuccess) {
        ivars->trusted = driver->ClientIsTrusted(entitlements);
        if (entitlements) entitlements->release();
    }
    os_log(OS_LOG_DEFAULT, "XLRDriver: user client opened, %{public}s", ivars->trusted ? "trusted" : "not trusted");
    ret = driver->AttachClient(this);
    ivars->attached = ret == kIOReturnSuccess;
    return ret;
}

kern_return_t
IMPL(XLRDriverUserClient, Stop)
{
    // After DetachClient returns, the driver sends this client no more events.
    os_log(OS_LOG_DEFAULT, "XLRDriver: user client Stop");
    if (ivars->attached) ivars->driver->DetachClient(this);
    ivars->attached = false;
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t XLRDriverUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments * arguments,
                                                  const IOUserClientMethodDispatch * dispatch, OSObject * target,
                                                  void * reference)
{
    switch (selector) {
    case XLRSelectorInfo: {
        if (arguments->structureOutputDescriptor) return kIOReturnBadArgument;
        OSData * info = nullptr;
        kern_return_t ret = ivars->driver->CopyInfo(&info);
        if (ret != kIOReturnSuccess) return ret;
        if (info->getLength() > arguments->structureOutputMaximumSize) {
            info->release();
            return kIOReturnNoSpace;
        }
        arguments->structureOutput = info;
        return kIOReturnSuccess;
    }
    case XLRSelectorCommand: {
        // Commands are at most 12 + 1024 bytes, so they always arrive inline.
        if (!arguments->structureInput || arguments->structureInputDescriptor || arguments->structureOutputDescriptor)
            return kIOReturnBadArgument;
        OSData * reply = nullptr;
        kern_return_t ret = ivars->driver->ExecuteCommand(arguments->structureInput, &reply, ivars->trusted);
        if (ret != kIOReturnSuccess) return ret;
        if (reply->getLength() > arguments->structureOutputMaximumSize) {
            reply->release();
            return kIOReturnNoSpace;
        }
        arguments->structureOutput = reply;
        return kIOReturnSuccess;
    }
    case XLRSelectorSubscribe:
        if (!arguments->completion) return kIOReturnBadArgument;
        ivars->driver->SetSubscriber(this, arguments->completion);
        return kIOReturnSuccess;
    case XLRSelectorClientTrust:
        if (arguments->scalarOutputCount < 1) return kIOReturnBadArgument;
        arguments->scalarOutput[0] = ivars->trusted;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    case XLRSelectorReenumerate:
        return ivars->driver->Reenumerate();
    case XLRSelectorStreamStatus:
        if (arguments->scalarOutputCount < 1) return kIOReturnBadArgument;
        arguments->scalarOutput[0] = XLRStreamOwnerApple;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    default:
        return super::ExternalMethod(selector, arguments, dispatch, target, reference);
    }
}
