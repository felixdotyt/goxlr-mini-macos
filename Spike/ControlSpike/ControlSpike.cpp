// Phase 4 step 0 control-channel spike (ADR 0003). See ControlSpike.iig.
//
// Properties on the driver object (scope global, element main, plist values):
//   'xinf' info     read-only  {spike, version, blob: OSData 00..0f, timebase}
//   'xcmd' command  settable   {op: echo|events|device|reject, ...}
//   'xrep' reply    read-only  the result of the last accepted command
//   'xevt' events   read-only  {seq, t: mach_absolute_time} when events run
//   'xs00'          read-only  String, no qualifier: "plain"
//   'xs01'          read-only  String, String qualifier "q": "qualified"
//   'xd01'          read-only  Dictionary, String qualifier "q": {a: "b"}
// Read-only properties are ControlSpikeProperty, which logs every value fetch.
// The 'device' command is disabled since v5: reading its plist property crashed
// coreaudiod (ADR 0003 finding 2). The 'exit' command stops the dext process,
// so the kernel relaunches the newest installed version.
// Since v9 the driver also opens ControlSpikeUserClient for user-client type
// 'xlrc' (ADR 0003 option (a)); see ControlSpikeUserClient.iig.

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSCollections.h>
#include <DriverKit/OSSerialization.h>
#include <AudioDriverKit/AudioDriverKit.h>

#include "ControlSpike.h"
#include "ControlSpikeCommand.h"
#include "ControlSpikeProperty.h"
#include "ControlSpikeUserClient.h"

namespace {
constexpr IOUserAudioObjectPropertySelector kInfo = 'xinf';
constexpr IOUserAudioObjectPropertySelector kCommand = 'xcmd';
constexpr IOUserAudioObjectPropertySelector kReply = 'xrep';
constexpr IOUserAudioObjectPropertySelector kEvents = 'xevt';
constexpr IOUserAudioObjectPropertySelector kDeviceInfo = 'xdev';
constexpr IOUserAudioObjectPropertySelector kPlainString = 'xs00';
constexpr IOUserAudioObjectPropertySelector kQualifiedString = 'xs01';
constexpr IOUserAudioObjectPropertySelector kQualifiedDictionary = 'xd01';
constexpr uint32_t kControlUserClientType = 'xlrc';
constexpr uint64_t kVersion = 14;
constexpr uint64_t kMaxEvents = 100000;
constexpr uint64_t kMinIntervalUs = 1000;

IOUserAudioObjectPropertyAddress address(IOUserAudioObjectPropertySelector selector)
{
    return { selector, IOUserAudioObjectPropertyScope::Global, IOUserAudioObjectPropertyElementMain };
}

OSSharedPtr<OSString> string(const char * value)
{
    return OSSharedPtr(OSString::withCString(value), OSNoRetain);
}

void putNumber(OSDictionary * dictionary, const char * key, uint64_t value)
{
    auto number = OSSharedPtr(OSNumber::withNumber(value, 64), OSNoRetain);
    dictionary->setObject(key, number.get());
}

void putString(OSDictionary * dictionary, const char * key, const char * value)
{
    auto text = string(value);
    dictionary->setObject(key, text.get());
}

uint64_t numberValue(OSDictionary * dictionary, const char * key, uint64_t fallback)
{
    OSNumber * value = OSDynamicCast(OSNumber, dictionary->getObject(key));
    return value ? value->unsigned64BitValue() : fallback;
}

// Names the class of a value the host sent, so the client can see how the HAL
// translated its CF types.
const char * className(OSObject * value)
{
    if (!value) return "none";
    if (OSDynamicCast(OSData, value)) return "OSData";
    if (OSDynamicCast(OSString, value)) return "OSString";
    if (OSDynamicCast(OSNumber, value)) return "OSNumber";
    if (OSDynamicCast(OSBoolean, value)) return "OSBoolean";
    if (OSDynamicCast(OSDictionary, value)) return "OSDictionary";
    if (OSDynamicCast(OSArray, value)) return "OSArray";
    return "other";
}

OSSharedPtr<IOUserAudioCustomProperty> readOnlyProperty(IOUserAudioDriver * driver,
                                                        IOUserAudioObjectPropertySelector selector,
                                                        IOUserAudioCustomPropertyDataType qualifier = IOUserAudioCustomPropertyDataType::None,
                                                        IOUserAudioCustomPropertyDataType data = IOUserAudioCustomPropertyDataType::Dictionary)
{
    auto property = OSSharedPtr(OSTypeAlloc(ControlSpikeProperty), OSNoRetain);
    if (!property || !property->init(driver, address(selector), false, qualifier, data)) return nullptr;
    return OSSharedPtr<IOUserAudioCustomProperty>(property);
}

void fourCC(IOUserAudioObjectPropertySelector selector, char out[5])
{
    for (int i = 0; i < 4; i++) out[i] = (char)(selector >> (24 - 8 * i));
    out[4] = 0;
}

// Stores a value and logs the result, which the framework doesn't report anywhere else.
kern_return_t store(IOUserAudioCustomProperty * property, const char * name, OSObject * qualifier, OSObject * value)
{
    kern_return_t ret = property->SetQualifierAndDataValue(qualifier, value);
    os_log(OS_LOG_DEFAULT, "XLRSpike: SetQualifierAndDataValue %{public}s 0x%x", name, ret);
    return ret;
}
}

struct ControlSpike_IVars {
    OSSharedPtr<IODispatchQueue> queue;
    OSSharedPtr<IOTimerDispatchSource> timer;
    OSSharedPtr<OSAction> timerAction;
    OSSharedPtr<IOUserAudioCustomProperty> info;
    OSSharedPtr<ControlSpikeCommand> command;
    OSSharedPtr<IOUserAudioCustomProperty> reply;
    OSSharedPtr<IOUserAudioCustomProperty> events;
    OSSharedPtr<IOUserAudioDevice> device;
    OSSharedPtr<IOUserAudioCustomProperty> plainString;
    OSSharedPtr<IOUserAudioCustomProperty> qualifiedString;
    OSSharedPtr<IOUserAudioCustomProperty> qualifiedDictionary;
    mach_timebase_info_data_t timebase;
    uint64_t commands;
    uint64_t eventSeq;
    uint64_t eventsLeft;
    uint64_t eventInterval;
};

struct ControlSpikeCommand_IVars {
    ControlSpike * driver;
};

bool ControlSpike::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(ControlSpike_IVars, 1);
    return ivars != nullptr;
}

void ControlSpike::free()
{
    if (ivars) {
        ivars->device.reset();
        ivars->plainString.reset();
        ivars->qualifiedString.reset();
        ivars->qualifiedDictionary.reset();
        ivars->events.reset();
        ivars->reply.reset();
        ivars->command.reset();
        ivars->info.reset();
        ivars->timerAction.reset();
        ivars->timer.reset();
        ivars->queue.reset();
    }
    IOSafeDeleteNULL(ivars, ControlSpike_IVars, 1);
    super::free();
}

kern_return_t
IMPL(ControlSpike, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "XLRSpike: ControlSpike Start ret=0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;

    mach_timebase_info(&ivars->timebase);
    IODispatchQueue * queue = nullptr;
    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &queue);
    if (ret != kIOReturnSuccess) return ret;
    ivars->queue = OSSharedPtr(queue, OSNoRetain);

    IOTimerDispatchSource * timer = nullptr;
    ret = IOTimerDispatchSource::Create(queue, &timer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timer = OSSharedPtr(timer, OSNoRetain);
    OSAction * action = nullptr;
    ret = CreateActionEventTimerFired(0, &action);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timerAction = OSSharedPtr(action, OSNoRetain);
    ret = timer->SetHandler(action);
    if (ret != kIOReturnSuccess) return ret;

    auto name = string("XLR Control Spike");
    SetName(name.get());

    auto info = OSSharedPtr(OSDictionary::withCapacity(5), OSNoRetain);
    uint8_t blob[16];
    for (uint8_t i = 0; i < sizeof blob; i++) blob[i] = i;
    auto blobData = OSSharedPtr(OSData::withBytes(blob, sizeof blob), OSNoRetain);
    putString(info.get(), "spike", "control");
    putNumber(info.get(), "version", kVersion);
    info->setObject("blob", blobData.get());
    putNumber(info.get(), "timebaseNumer", ivars->timebase.numer);
    putNumber(info.get(), "timebaseDenom", ivars->timebase.denom);
    ivars->info = readOnlyProperty(this, kInfo);
    ivars->reply = readOnlyProperty(this, kReply);
    ivars->events = readOnlyProperty(this, kEvents);
    auto empty = OSSharedPtr(OSDictionary::withCapacity(1), OSNoRetain);
    if (!ivars->info || !ivars->reply || !ivars->events) return kIOReturnNoMemory;
    store(ivars->info.get(), "xinf", nullptr, info.get());
    store(ivars->reply.get(), "xrep", nullptr, empty.get());
    store(ivars->events.get(), "xevt", nullptr, empty.get());

    using Type = IOUserAudioCustomPropertyDataType;
    ivars->plainString = readOnlyProperty(this, kPlainString, Type::None, Type::String);
    ivars->qualifiedString = readOnlyProperty(this, kQualifiedString, Type::String, Type::String);
    ivars->qualifiedDictionary = readOnlyProperty(this, kQualifiedDictionary, Type::String, Type::Dictionary);
    if (!ivars->plainString || !ivars->qualifiedString || !ivars->qualifiedDictionary) return kIOReturnNoMemory;
    auto plain = string("plain");
    auto qualified = string("qualified");
    auto q = string("q");
    auto ab = OSSharedPtr(OSDictionary::withCapacity(1), OSNoRetain);
    putString(ab.get(), "a", "b");
    store(ivars->plainString.get(), "xs00", nullptr, plain.get());
    store(ivars->qualifiedString.get(), "xs01", q.get(), qualified.get());
    store(ivars->qualifiedDictionary.get(), "xd01", q.get(), ab.get());

    ivars->command = OSSharedPtr(OSTypeAlloc(ControlSpikeCommand), OSNoRetain);
    if (!ivars->command || !ivars->command->init(this, address(kCommand), true,
                                                 IOUserAudioCustomPropertyDataType::None,
                                                 IOUserAudioCustomPropertyDataType::Dictionary))
        return kIOReturnNoMemory;
    store(ivars->command.get(), "xcmd", nullptr, empty.get());

    IOUserAudioCustomProperty * properties[] = { ivars->info.get(), ivars->command.get(), ivars->reply.get(),
                                                 ivars->events.get(), ivars->plainString.get(),
                                                 ivars->qualifiedString.get(), ivars->qualifiedDictionary.get() };
    for (IOUserAudioCustomProperty * property : properties) {
        ret = AddCustomProperty(property);
        if (ret != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT, "XLRSpike: AddCustomProperty failed 0x%x", ret);
            return ret;
        }
    }
    ret = RegisterService();
    os_log(OS_LOG_DEFAULT, "XLRSpike: properties added, RegisterService ret=0x%x", ret);
    return ret;
}

kern_return_t
IMPL(ControlSpike, NewUserClient)
{
    if (in_type != kControlUserClientType) return NewUserClient(in_type, out_user_client, SUPERDISPATCH);
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "XLRControlUserClientProperties", &client);
    os_log(OS_LOG_DEFAULT, "XLRSpike: NewUserClient 'xlrc' Create ret=0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;
    *out_user_client = OSDynamicCast(IOUserClient, client);
    if (!*out_user_client) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

kern_return_t
IMPL(ControlSpike, Stop)
{
    os_log(OS_LOG_DEFAULT, "XLRSpike: ControlSpike Stop after %llu commands, %llu events",
           ivars->commands, ivars->eventSeq);
    if (ivars->device) RemoveObject(ivars->device.get());
    if (!ivars->timer) return Stop(provider, SUPERDISPATCH);
    // Finish stopping only once the timer's cancel handler has run, so free()
    // can't release the timer while that handler is still pending.
    ivars->timer->Cancel(^{
        Stop(provider, SUPERDISPATCH);
    });
    return kIOReturnSuccess;
}

// Runs on the AudioDriverKit side of a host write. Anything that updates
// another property is deferred to the default queue; the blocks' copies of
// `reply` keep it retained.
kern_return_t ControlSpike::HandleCommand(OSObject * data)
{
    OSDictionary * command = OSDynamicCast(OSDictionary, data);
    OSString * op = command ? OSDynamicCast(OSString, command->getObject("op")) : nullptr;
    if (!op) {
        os_log(OS_LOG_DEFAULT, "XLRSpike: command rejected: not a dictionary with an op (%s)", className(data));
        return kIOReturnBadArgument;
    }
    uint64_t count = ++ivars->commands;
    OSObject * payload = command->getObject("payload");
    os_log(OS_LOG_DEFAULT, "XLRSpike: command %llu op=%{public}s payload=%{public}s", count, op->getCStringNoCopy(),
           className(payload));
    if (OSDictionary * nested = OSDynamicCast(OSDictionary, payload))
        os_log(OS_LOG_DEFAULT, "XLRSpike: nested payload value=%{public}s", className(nested->getObject("nested")));

    auto reply = OSSharedPtr(OSDictionary::withCapacity(6), OSNoRetain);
    reply->setObject("op", op);
    putNumber(reply.get(), "count", count);

    if (op->isEqualTo("reject")) {
        return kIOReturnNotPermitted;
    } else if (op->isEqualTo("exit")) {
        os_log(OS_LOG_DEFAULT, "XLRSpike: exit requested; trapping so the kernel relaunches the newest version");
        ivars->queue->DispatchAsync(^{ __builtin_trap(); });
        return kIOReturnSuccess;
    } else if (op->isEqualTo("echo")) {
        putString(reply.get(), "payloadClass", className(payload));
        if (OSData * bytes = OSDynamicCast(OSData, payload)) putNumber(reply.get(), "payloadLength", bytes->getLength());
        if (payload) reply->setObject("payload", payload);
    } else if (op->isEqualTo("events")) {
        uint64_t events = numberValue(command, "count", 100);
        uint64_t intervalUs = numberValue(command, "intervalUs", 20000);
        if (events > kMaxEvents || intervalUs < kMinIntervalUs) return kIOReturnBadArgument;
        uint64_t interval = intervalUs * 1000 * ivars->timebase.denom / ivars->timebase.numer;
        ivars->queue->DispatchAsync(^{
            ivars->eventsLeft = events;
            ivars->eventInterval = interval;
            ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + interval, 0);
        });
        putNumber(reply.get(), "events", events);
        putNumber(reply.get(), "intervalUs", intervalUs);
    } else if (op->isEqualTo("device")) {
        // v4: reading this device's plist property crashed coreaudiod (ADR 0003).
        return kIOReturnUnsupported;
        ivars->queue->DispatchAsync(^{
            if (!ivars->device) {
                auto uid = string("XLRSpikeDevice");
                auto model = string("XLRSpike");
                auto maker = string("XLR");
                auto device = IOUserAudioDevice::Create(this, false, uid.get(), model.get(), maker.get(), 512);
                auto marker = OSSharedPtr(OSDictionary::withCapacity(1), OSNoRetain);
                putString(marker.get(), "device", "spike");
                auto property = readOnlyProperty(this, kDeviceInfo);
                if (device && property) {
                    double rate = 48000;
                    device->SetAvailableSampleRates(&rate, 1);
                    device->SetSampleRate(rate);
                    device->SetCanBeDefaultInputDevice(false);
                    device->SetCanBeDefaultOutputDevice(false);
                    device->SetCanBeDefaultSystemOutputDevice(false);
                    property->SetQualifierAndDataValue(nullptr, marker.get());
                    kern_return_t added = device->AddCustomProperty(property.get());
                    kern_return_t ret = AddObject(device.get());
                    IOUserAudioObjectPropertySelector changed[] = { 'dev#', 'ownd' };
                    PropertiesChanged(kIOUserAudioObjectIDDriver, changed, 2);
                    os_log(OS_LOG_DEFAULT, "XLRSpike: device id %u, AddCustomProperty 0x%x, AddObject 0x%x",
                           device->GetObjectID(), added, ret);
                    ivars->device = device;
                }
            }
            putNumber(reply.get(), "objectID", ivars->device ? ivars->device->GetObjectID() : 0);
            ivars->reply->SetQualifierAndDataValue(nullptr, reply.get());
            IOUserAudioObjectPropertySelector changed = kReply;
            PropertiesChanged(kIOUserAudioObjectIDDriver, &changed, 1);
        });
        return kIOReturnSuccess;
    } else {
        return kIOReturnUnsupported;
    }

    ivars->queue->DispatchAsync(^{
        store(ivars->reply.get(), "xrep", nullptr, reply.get());
        IOUserAudioObjectPropertySelector changed = kReply;
        PropertiesChanged(kIOUserAudioObjectIDDriver, &changed, 1);
    });
    return kIOReturnSuccess;
}

void
IMPL(ControlSpike, EventTimerFired)
{
    if (ivars->eventsLeft == 0) return;
    ivars->eventsLeft--;
    auto event = OSSharedPtr(OSDictionary::withCapacity(2), OSNoRetain);
    putNumber(event.get(), "seq", ++ivars->eventSeq);
    putNumber(event.get(), "t", mach_absolute_time());
    ivars->events->SetQualifierAndDataValue(nullptr, event.get());
    IOUserAudioObjectPropertySelector changed = kEvents;
    PropertiesChanged(kIOUserAudioObjectIDDriver, &changed, 1);
    if (ivars->eventsLeft > 0)
        ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, time + ivars->eventInterval, 0);
}

bool ControlSpikeCommand::init(IOUserAudioDriver * in_audio_driver,
                               IOUserAudioObjectPropertyAddress in_prop_addr,
                               bool in_is_property_settable,
                               IOUserAudioCustomPropertyDataType in_qualifier_data_type,
                               IOUserAudioCustomPropertyDataType in_data_type)
{
    if (!super::init(in_audio_driver, in_prop_addr, in_is_property_settable, in_qualifier_data_type, in_data_type))
        return false;
    ivars = IONewZero(ControlSpikeCommand_IVars, 1);
    if (!ivars) return false;
    ivars->driver = OSDynamicCast(ControlSpike, in_audio_driver);
    return ivars->driver != nullptr;
}

void ControlSpikeCommand::free()
{
    IOSafeDeleteNULL(ivars, ControlSpikeCommand_IVars, 1);
    super::free();
}

kern_return_t ControlSpikeCommand::HandleChangeCustomPropertyDataValueWithQualifier(OSObject * in_qualifier_data,
                                                                                    OSObject * in_data)
{
    kern_return_t ret = ivars->driver->HandleCommand(in_data);
    if (ret != kIOReturnSuccess) return ret;
    return super::HandleChangeCustomPropertyDataValueWithQualifier(in_qualifier_data, in_data);
}

kern_return_t ControlSpikeProperty::GetCustomPropertyValueWithQualifier(OSObject * in_qualifier_data,
                                                                        OSObject ** out_data)
{
    kern_return_t ret = super::GetCustomPropertyValueWithQualifier(in_qualifier_data, out_data);
    char name[5];
    fourCC(GetCustomPropertyInfo().mSelector, name);
    os_log(OS_LOG_DEFAULT, "XLRSpike: get %{public}s qualifier=%{public}s -> 0x%x value=%{public}s", name,
           className(in_qualifier_data), ret, className(out_data ? *out_data : nullptr));
    // The framework sizes the reply by serializing the value this way (v8).
    OSObject * value = out_data ? *out_data : nullptr;
    if (ret == kIOReturnSuccess && value) {
        OSSerialization * serialization = OSSerialization::createFromObject(value);
        size_t length = 0;
        const void * buffer = serialization ? serialization->finalizeBuffer(&length) : nullptr;
        char hex[2 * 24 + 1] = {};
        const uint8_t * bytes = static_cast<const uint8_t *>(buffer);
        for (size_t i = 0; bytes && i < length && i < 24; i++) {
            static const char digits[] = "0123456789abcdef";
            hex[2 * i] = digits[bytes[i] >> 4];
            hex[2 * i + 1] = digits[bytes[i] & 0xf];
        }
        os_log(OS_LOG_DEFAULT, "XLRSpike: serialize %{public}s object=%d buffer=%d length=%zu bytes=%{public}s", name,
               serialization != nullptr, buffer != nullptr, length, hex);
        if (buffer) OSSerialization::freeBuffer(buffer, length);
        if (serialization) serialization->release();
    }
    return ret;
}

struct ControlSpikeUserClient_IVars {
    OSSharedPtr<IODispatchQueue> queue;
    OSSharedPtr<IOTimerDispatchSource> timer;
    OSSharedPtr<OSAction> timerAction;
    OSSharedPtr<OSAction> subscriber;
    mach_timebase_info_data_t timebase;
    uint64_t calls;
    uint64_t eventSeq;
    uint64_t eventsLeft;
    uint64_t eventInterval;
};

bool ControlSpikeUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(ControlSpikeUserClient_IVars, 1);
    return ivars != nullptr;
}

void ControlSpikeUserClient::free()
{
    if (ivars) {
        ivars->subscriber.reset();
        ivars->timerAction.reset();
        ivars->timer.reset();
        ivars->queue.reset();
    }
    IOSafeDeleteNULL(ivars, ControlSpikeUserClient_IVars, 1);
    super::free();
}

kern_return_t
IMPL(ControlSpikeUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    mach_timebase_info(&ivars->timebase);
    IODispatchQueue * queue = nullptr;
    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &queue);
    if (ret != kIOReturnSuccess) return ret;
    ivars->queue = OSSharedPtr(queue, OSNoRetain);
    IOTimerDispatchSource * timer = nullptr;
    ret = IOTimerDispatchSource::Create(queue, &timer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timer = OSSharedPtr(timer, OSNoRetain);
    OSAction * action = nullptr;
    ret = CreateActionEventTimerFired(0, &action);
    if (ret != kIOReturnSuccess) return ret;
    ivars->timerAction = OSSharedPtr(action, OSNoRetain);
    ret = timer->SetHandler(action);
    os_log(OS_LOG_DEFAULT, "XLRSpike: user client Start ret=0x%x", ret);
    return ret;
}

kern_return_t
IMPL(ControlSpikeUserClient, Stop)
{
    os_log(OS_LOG_DEFAULT, "XLRSpike: user client Stop after %llu calls, %llu events", ivars->calls, ivars->eventSeq);
    ivars->subscriber.reset();
    if (!ivars->timer) return Stop(provider, SUPERDISPATCH);
    // v9 crashed in TimerDispatchSourceWasCanceled when Stop returned before
    // the cancel handler ran and free() released the timer under it.
    ivars->timer->Cancel(^{
        Stop(provider, SUPERDISPATCH);
    });
    return kIOReturnSuccess;
}

kern_return_t ControlSpikeUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments * arguments,
                                                     const IOUserClientMethodDispatch * dispatch, OSObject * target,
                                                     void * reference)
{
    ivars->calls++;
    switch (selector) {
    case 0: {
        OSData * input = arguments->structureInput;
        if (!input || arguments->structureOutputDescriptor) return kIOReturnBadArgument;
        if (input->getLength() > arguments->structureOutputMaximumSize) return kIOReturnNoSpace;
        input->retain();
        arguments->structureOutput = input;
        return kIOReturnSuccess;
    }
    case 1:
        if (arguments->scalarOutputCount < 3) return kIOReturnBadArgument;
        arguments->scalarOutput[0] = kVersion;
        arguments->scalarOutput[1] = ivars->timebase.numer;
        arguments->scalarOutput[2] = ivars->timebase.denom;
        arguments->scalarOutputCount = 3;
        return kIOReturnSuccess;
    case 2:
        if (!arguments->completion) return kIOReturnBadArgument;
        ivars->subscriber.reset(arguments->completion, OSRetain);
        os_log(OS_LOG_DEFAULT, "XLRSpike: user client subscribed");
        return kIOReturnSuccess;
    case 3: {
        if (arguments->scalarInputCount < 2) return kIOReturnBadArgument;
        uint64_t events = arguments->scalarInput[0], intervalUs = arguments->scalarInput[1];
        if (events > kMaxEvents || intervalUs < kMinIntervalUs) return kIOReturnBadArgument;
        if (!ivars->subscriber) return kIOReturnNotReady;
        ivars->eventsLeft = events;
        ivars->eventInterval = intervalUs * 1000 * ivars->timebase.denom / ivars->timebase.numer;
        return ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + ivars->eventInterval, 0);
    }
    default:
        return super::ExternalMethod(selector, arguments, dispatch, target, reference);
    }
}

void
IMPL(ControlSpikeUserClient, EventTimerFired)
{
    if (ivars->eventsLeft == 0 || !ivars->subscriber) return;
    ivars->eventsLeft--;
    IOUserClientAsyncArgumentsArray data = {};
    data[0] = ++ivars->eventSeq;
    data[1] = mach_absolute_time();
    AsyncCompletion(ivars->subscriber.get(), kIOReturnSuccess, data, 2);
    if (ivars->eventsLeft > 0)
        ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, time + ivars->eventInterval, 0);
}
