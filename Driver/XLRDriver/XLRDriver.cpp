// XLR driver, Phase 4. See XLRDriver.iig, docs/protocol/SPEC.md and ADRs 0003-0004.
//
// Everything that touches the device runs on one serial queue, "Transport":
// the start sequence, client commands and the input-state poll. That is the
// one-command-in-flight rule of SPEC.md section 4.
//
// Clients are tracked under a lock, not on that queue: a user client can stop
// after the driver has cancelled the queue, and a synchronous call onto a
// cancelled queue never returns, which kept the driver and its process alive
// (LEDGER L-124). Calls that do use the queue count themselves in `inFlight`,
// and Stop waits for them before cancelling it.

#include <os/log.h>

#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSSharedPtr.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/IOUSBHostFamilyDefinitions.h>
#include <USBDriverKit/USBDriverKitDefs.h>

#include "Policy.h"
#include "XLRDriver.h"
#include "XLRDriverABI.h"

namespace {
constexpr uint32_t kDriverVersion = 10;
// Writes are enabled one PROMPT.md Phase 5 risk tier at a time (policy-table.json
// "tier"): 1 LEDs and colours, 2 fader assignment and volumes, 3 mute, 4 routing,
// 5 mic type and gain, 6 EQ and dynamics. Higher tiers are refused as
// writesDisabled. Phantom power additionally needs a team-signed client.
constexpr uint8_t kWriteTier = 6;

constexpr uint16_t kMiniProduct = 0x8FE4, kFullProduct = 0x8FE0;
constexpr uint8_t kConfiguration = 1;

// SPEC.md section 1
constexpr uint8_t kVendorIn = 0xC1, kVendorOut = 0x41;
constexpr uint8_t kRequestGlobalData = 0, kRequestReset = 1, kRequestCommand = 2, kRequestReply = 3;
constexpr uint32_t kTransferTimeoutMs = 200;
// SPEC.md section 2
constexpr uint16_t kGlobalDataLength = 24;
constexpr uint32_t kMagic0 = 0x04061973, kMagic1 = 0x18101966;
// SPEC.md sections 3 and 5
constexpr uint32_t kHeaderLength = 16;
constexpr uint64_t kReplyWaitMs = 3000;
constexpr uint64_t kReplyPollMiniMs = 10, kReplyPollFullMs = 3;
// SPEC.md sections 7, 9 and 10
constexpr uint32_t kVersionsCategory = 0x80F, kVersionsLength = 24;
constexpr uint32_t kInputStateCategory = 0x800, kInputStateLength = 12;
constexpr uint32_t kPollIntervalMs = 20;
constexpr uint32_t kSlowPollIntervalMs = 1000;
constexpr uint64_t kSlowAfterFailures = 10;

constexpr uint32_t kMaxClients = 16;

struct Outcome {
    uint32_t error = XLRTransportErrorNone;
    uint32_t dcpStatus = 0;
    kern_return_t ioReturn = kIOReturnSuccess;
    uint32_t payloadLength = 0;
    // The reply header, when one was read: for logs (never the payload).
    bool haveReply = false;
    uint16_t replyBytes = 0, replyLength = 0, replySequence = 0;
    uint32_t replyOpcode = 0, replyStatus = 0;
    bool ok() const { return error == XLRTransportErrorNone; }
};

Outcome failure(uint32_t error, kern_return_t ioReturn = kIOReturnSuccess, uint32_t dcpStatus = 0)
{
    Outcome outcome;
    outcome.error = error;
    outcome.ioReturn = ioReturn;
    outcome.dcpStatus = dcpStatus;
    return outcome;
}

uint32_t get32(const uint8_t * p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t get16(const uint8_t * p) { return uint16_t(p[0] | p[1] << 8); }
void put32(uint8_t * p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = uint8_t(v >> (8 * i)); }
void put16(uint8_t * p, uint16_t v) { p[0] = uint8_t(v); p[1] = uint8_t(v >> 8); }
uint64_t le64(const uint8_t * p, size_t n) { uint64_t v = 0; for (size_t i = 0; i < n; i++) v |= uint64_t(p[i]) << (8 * i); return v; }

struct Client {
    IOUserClient * client;  // retained
    OSAction * subscriber;  // retained, or null
};
} // namespace

struct XLRDriver_IVars {
    OSSharedPtr<IOUSBHostDevice> device;
    OSSharedPtr<IODispatchQueue> transport;
    // Reset() terminates this driver, whose Stop needs the other queues, so it
    // runs on a queue of its own.
    OSSharedPtr<IODispatchQueue> resetQueue;
    OSSharedPtr<IOTimerDispatchSource> pollTimer;
    OSSharedPtr<OSAction> pollAction;
    OSSharedPtr<IOBufferMemoryDescriptor> out, in;
    OSSharedPtr<OSString> trustedTeam; // from the personality; null trusts no client
    uint8_t * outBytes;
    uint8_t * inBytes;
    mach_timebase_info_data_t timebase;
    bool stopping;  // atomic access only
    uint32_t inFlight; // synchronous calls on the transport queue; atomic access only
    bool opened;
    IOLock * clientLock; // guards clients and clientCount

    uint32_t state, startFailure, startError, startDcpStatus;
    kern_return_t failureReturn;
    uint32_t model;
    xlr::policy::Model policyModel;
    uint32_t dcpVersion, maxPayload;
    uint16_t sequence;
    xlr::policy::Firmware firmware;
    uint8_t versions[kVersionsLength];
    uint8_t inputState[kInputStateLength];
    bool haveInputState;
    uint32_t pollInterval;
    uint64_t consecutivePollFailures;

    uint64_t commandsSent, commandsRejected, commandsFailed, polls, pollFailures, events;
    Client clients[kMaxClients];
    uint32_t clientCount;
};

namespace {

bool stopping(XLRDriver_IVars * ivars) { return __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE); }

uint64_t elapsedMs(XLRDriver_IVars * ivars, uint64_t start)
{
    return (mach_absolute_time() - start) * ivars->timebase.numer / ivars->timebase.denom / 1000000;
}

uint64_t ticksForMs(XLRDriver_IVars * ivars, uint64_t ms)
{
    return ms * 1000000 * ivars->timebase.denom / ivars->timebase.numer;
}

kern_return_t deviceRequest(XLRDriver * driver, XLRDriver_IVars * ivars, uint8_t type, uint8_t request,
                            uint16_t length, IOMemoryDescriptor * buffer, uint16_t * done)
{
    *done = 0;
    return ivars->device->DeviceRequest(driver, type, request, 0, 0, length, length ? buffer : nullptr, done,
                                        kTransferTimeoutMs);
}

// Polling mode (SPEC.md section 5): the dext doesn't own interface 0, so it
// reads bRequest 3 until the device stops STALLing it.
Outcome waitForReply(XLRDriver * driver, XLRDriver_IVars * ivars, uint16_t * done)
{
    uint64_t start = mach_absolute_time();
    uint64_t step = ivars->model == XLRModelFull ? kReplyPollFullMs : kReplyPollMiniMs;
    for (;;) {
        if (stopping(ivars)) return failure(XLRTransportErrorStopping);
        kern_return_t ret = deviceRequest(driver, ivars, kVendorIn, kRequestReply,
                                          uint16_t(ivars->maxPayload + kHeaderLength), ivars->in.get(), done);
        if (ret == kIOReturnSuccess) return Outcome();
        if (ret != kUSBHostReturnPipeStalled) return failure(XLRTransportErrorTransfer, ret);
        if (elapsedMs(ivars, start) >= kReplyWaitMs) return failure(XLRTransportErrorWaitTimeout, ret);
        IOSleep(step);
    }
}

// One command and its reply, checked in SPEC.md section 3's order.
Outcome sendOnce(XLRDriver * driver, XLRDriver_IVars * ivars, uint32_t category, uint32_t index,
                 const uint8_t * payload, uint32_t length, uint32_t expected, bool exact, uint8_t * replyPayload)
{
    uint32_t opcode = (category & 0xFFF) << 12 | (index & 0xFFF);
    uint8_t * header = ivars->outBytes;
    put32(header, opcode);
    put16(header + 4, uint16_t(length));
    put16(header + 6, ivars->sequence);
    put32(header + 8, 0);
    put32(header + 12, 0);
    if (length) __builtin_memcpy(header + kHeaderLength, payload, length);

    uint16_t done = 0;
    kern_return_t ret = deviceRequest(driver, ivars, kVendorOut, kRequestCommand, uint16_t(kHeaderLength + length),
                                      ivars->out.get(), &done);
    if (ret == kUSBHostReturnPipeStalled) return failure(XLRTransportErrorStall, ret);
    if (ret != kIOReturnSuccess) return failure(XLRTransportErrorTransfer, ret);

    Outcome waited = waitForReply(driver, ivars, &done);
    if (!waited.ok()) return waited;
    const uint8_t * reply = ivars->inBytes;
    Outcome result;
    if (done < kHeaderLength) {
        result = failure(XLRTransportErrorReplyTooShort);
        result.replyBytes = done;
        return result;
    }
    result.haveReply = true;
    result.replyBytes = done;
    result.replyOpcode = get32(reply);
    result.replyLength = get16(reply + 4);
    result.replySequence = get16(reply + 6);
    result.replyStatus = get32(reply + 8);
    auto fail = [&](uint32_t error) {
        result.error = error;
        return result;
    };
    if (result.replyOpcode != opcode) return fail(XLRTransportErrorOpcodeMismatch);
    if (result.replySequence != ivars->sequence) return fail(XLRTransportErrorSequenceMismatch);
    if (result.replyLength + kHeaderLength != done) return fail(XLRTransportErrorLengthMismatch);
    if (result.replyLength > expected) return fail(XLRTransportErrorReplyTooLarge);
    if (exact && result.replyLength != expected) return fail(XLRTransportErrorLengthMismatch);
    ivars->sequence++; // a completed reply (SPEC.md section 4)
    if (result.replyStatus != 0) {
        result.dcpStatus = result.replyStatus;
        return fail(XLRTransportErrorDcpStatus);
    }
    if (replyPayload && result.replyLength) __builtin_memcpy(replyPayload, reply + kHeaderLength, result.replyLength);
    result.payloadLength = result.replyLength;
    return result;
}

void logFailure(const char * what, uint32_t category, uint32_t index, uint16_t sequence, const Outcome & outcome)
{
    os_log(OS_LOG_DEFAULT,
           "XLRDriver: %{public}s 0x%03x:%u seq %u failed: error %u, 0x%x, status %u; reply %u bytes: opcode 0x%x, "
           "length %u, seq %u, status %u",
           what, category, index, sequence, outcome.error, outcome.ioReturn, outcome.dcpStatus, outcome.replyBytes,
           outcome.replyOpcode, outcome.replyLength, outcome.replySequence, outcome.replyStatus);
}

// SPEC.md section 4.
Outcome reset(XLRDriver * driver, XLRDriver_IVars * ivars)
{
    if (ivars->dcpVersion > 1) {
        uint16_t done = 0;
        kern_return_t ret = deviceRequest(driver, ivars, kVendorOut, kRequestReset, 0, nullptr, &done);
        if (ret == kUSBHostReturnPipeStalled) return failure(XLRTransportErrorStall, ret);
        if (ret != kIOReturnSuccess) return failure(XLRTransportErrorTransfer, ret);
        Outcome waited = waitForReply(driver, ivars, &done);
        if (!waited.ok()) return waited;
        // No vector specifies this reply; log its header (never identity) and accept it.
        const uint8_t * r = ivars->inBytes;
        os_log(OS_LOG_DEFAULT, "XLRDriver: reset reply %u bytes, opcode 0x%x, length %u, seq %u, status %u", done,
               done >= 4 ? get32(r) : 0, done >= 6 ? get16(r + 4) : 0, done >= 8 ? get16(r + 6) : 0,
               done >= 12 ? get32(r + 8) : 0);
        // The reset's reply is a completed reply for sequence 0, so the next
        // command is sent with 1 (SPEC.md section 4; H2 run 1 sent 0 and the
        // Mini refused it).
        ivars->sequence = 1;
        return Outcome();
    }
    // Command 0:0 with sequence 0; its completed reply moves the counter to 1.
    ivars->sequence = 0;
    return sendOnce(driver, ivars, 0, 0, nullptr, 0, ivars->maxPayload, false, nullptr);
}

// A command with SPEC.md section 4's retry: on failure, one reset and one retry.
Outcome transact(XLRDriver * driver, XLRDriver_IVars * ivars, uint32_t category, uint32_t index,
                 const uint8_t * payload, uint32_t length, uint32_t expected, bool exact, uint8_t * replyPayload,
                 uint32_t * attempts)
{
    *attempts = 1;
    uint16_t sequence = ivars->sequence;
    Outcome first = sendOnce(driver, ivars, category, index, payload, length, expected, exact, replyPayload);
    if (first.ok() || first.error == XLRTransportErrorStopping) return first;
    logFailure("attempt 1 of", category, index, sequence, first);
    Outcome reset_ = reset(driver, ivars);
    if (!reset_.ok()) {
        os_log(OS_LOG_DEFAULT, "XLRDriver: reset after 0x%03x:%u failure %u failed: error %u, 0x%x", category, index,
               first.error, reset_.error, reset_.ioReturn);
        return first;
    }
    *attempts = 2;
    sequence = ivars->sequence;
    Outcome second = sendOnce(driver, ivars, category, index, payload, length, expected, exact, replyPayload);
    if (!second.ok() && second.error != XLRTransportErrorStopping) logFailure("attempt 2 of", category, index, sequence, second);
    return second;
}

void postEvent(XLRDriver_IVars * ivars, uint64_t kind, uint64_t a, uint64_t b)
{
    IOUserClientAsyncArgumentsArray data = {};
    data[0] = kind;
    data[1] = ++ivars->events;
    data[2] = a;
    data[3] = b;
    IOLockLock(ivars->clientLock);
    for (uint32_t i = 0; i < ivars->clientCount; i++)
        if (ivars->clients[i].subscriber)
            ivars->clients[i].client->AsyncCompletion(ivars->clients[i].subscriber, kIOReturnSuccess, data,
                                                      XLR_EVENT_VALUE_COUNT);
    IOLockUnlock(ivars->clientLock);
}

// Enter before a synchronous call onto the transport queue, leave after it.
// Refused once the driver is stopping, so nothing waits on a cancelled queue.
bool enterTransport(XLRDriver_IVars * ivars)
{
    // Sequentially consistent, paired with Stop: either this sees `stopping`, or
    // Stop sees the increment and waits.
    __atomic_add_fetch(&ivars->inFlight, 1, __ATOMIC_SEQ_CST);
    if (!__atomic_load_n(&ivars->stopping, __ATOMIC_SEQ_CST)) return true;
    __atomic_sub_fetch(&ivars->inFlight, 1, __ATOMIC_SEQ_CST);
    return false;
}

void leaveTransport(XLRDriver_IVars * ivars)
{
    __atomic_sub_fetch(&ivars->inFlight, 1, __ATOMIC_SEQ_CST);
}

void postInputState(XLRDriver_IVars * ivars)
{
    postEvent(ivars, XLREventKindInputState, le64(ivars->inputState, 8), le64(ivars->inputState + 8, 4));
}

void postDriverState(XLRDriver_IVars * ivars)
{
    postEvent(ivars, XLREventKindDriverState, ivars->state, ivars->startFailure);
}

void failStart(XLRDriver_IVars * ivars, uint32_t step, kern_return_t ret, const Outcome * outcome = nullptr)
{
    ivars->state = XLRDriverStateFailed;
    ivars->startFailure = step;
    ivars->failureReturn = ret;
    ivars->startError = outcome ? outcome->error : XLRTransportErrorNone;
    ivars->startDcpStatus = outcome ? outcome->dcpStatus : 0;
    os_log(OS_LOG_DEFAULT, "XLRDriver: start failed at step %u (XLRStartFailure), 0x%x, transport error %u, status %u",
           step, ret, ivars->startError, ivars->startDcpStatus);
    postDriverState(ivars);
}

// A protocol failure has no IOReturn of its own; the transport error says what failed.
kern_return_t outcomeReturn(const Outcome & outcome)
{
    return outcome.ioReturn != kIOReturnSuccess ? outcome.ioReturn : kIOReturnError;
}

// SPEC.md section 7, on the transport queue.
void startDevice(XLRDriver * driver, XLRDriver_IVars * ivars)
{
    // Step 1 (UAC2 SET CUR 48 kHz) is skipped: usbaudiod owns interface 0 and
    // sends it on every attach (ADR 0004, L-112).
    uint16_t done = 0;
    kern_return_t ret = deviceRequest(driver, ivars, kVendorIn, kRequestGlobalData, kGlobalDataLength,
                                      ivars->in.get(), &done);
    if (ret != kIOReturnSuccess || done != kGlobalDataLength)
        return failStart(ivars, XLRStartFailureGlobalData, ret != kIOReturnSuccess ? ret : kIOReturnUnderrun);
    const uint8_t * global = ivars->inBytes;
    if (get32(global) != kMagic0 || get32(global + 4) != kMagic1)
        return failStart(ivars, XLRStartFailureBadMagic, kIOReturnError);
    ivars->dcpVersion = get32(global + 8);
    ivars->maxPayload = get32(global + 16);
    os_log(OS_LOG_DEFAULT, "XLRDriver: global data: dcp_version %u, max_payload %u", ivars->dcpVersion,
           ivars->maxPayload);
    if (ivars->maxPayload > XLR_MAX_PAYLOAD || ivars->maxPayload < kVersionsLength)
        return failStart(ivars, XLRStartFailurePayloadLimit, kIOReturnUnsupported);

    Outcome outcome = reset(driver, ivars);
    if (!outcome.ok())
        return failStart(ivars, outcome.error == XLRTransportErrorStall ? XLRStartFailureUninitialised
                                                                        : XLRStartFailureReset,
                         outcomeReturn(outcome), &outcome);

    uint32_t attempts = 0;
    outcome = transact(driver, ivars, kVersionsCategory, 0, nullptr, 0, kVersionsLength, true, ivars->versions,
                       &attempts);
    if (!outcome.ok()) return failStart(ivars, XLRStartFailureVersions, outcomeReturn(outcome), &outcome);
    uint32_t word0 = get32(ivars->versions), build = get32(ivars->versions + 4);
    ivars->firmware = { word0 >> 12 & 0xF, word0 >> 8 & 0xF, word0 & 0xFF, build };
    os_log(OS_LOG_DEFAULT, "XLRDriver: firmware %u.%u.%u.%u (attempts %u)", ivars->firmware.major,
           ivars->firmware.minor, ivars->firmware.patch, ivars->firmware.build, attempts);
    // 0x80F:1 (serial and date) is device identity: the driver neither reads nor
    // keeps it. Clients may ask for it as a command (SPEC.md section 7 step 4).

    outcome = transact(driver, ivars, kInputStateCategory, 0, nullptr, 0, kInputStateLength, true, ivars->inputState,
                       &attempts);
    if (!outcome.ok()) return failStart(ivars, XLRStartFailureInputState, outcomeReturn(outcome), &outcome);
    ivars->haveInputState = true;

    ivars->state = XLRDriverStateReady;
    os_log(OS_LOG_DEFAULT, "XLRDriver: ready; polling input state every %u ms", ivars->pollInterval);
    postDriverState(ivars);
    postInputState(ivars);
    ivars->pollTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime,
                                 mach_absolute_time() + ticksForMs(ivars, ivars->pollInterval), 0);
}

void fillReply(uint8_t * buffer, uint32_t result, uint32_t detail, const Outcome * outcome, uint32_t attempts)
{
    XLRCommandReplyHeader header = {};
    header.result = result;
    header.detail = detail;
    header.attempts = attempts;
    if (outcome) {
        header.dcpStatus = outcome->dcpStatus;
        header.ioReturn = uint32_t(outcome->ioReturn);
        header.payloadLength = outcome->payloadLength;
    }
    __builtin_memcpy(buffer, &header, sizeof header);
}

} // namespace

// Live objects in this process, for the lifecycle logs (LEDGER L-124).
uint32_t gLiveDrivers;

bool XLRDriver::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(XLRDriver_IVars, 1);
    if (!ivars) return false;
    ivars->clientLock = IOLockAlloc();
    if (!ivars->clientLock) return false;
    os_log(OS_LOG_DEFAULT, "XLRDriver: init (%u live in this process)", __atomic_add_fetch(&gLiveDrivers, 1, __ATOMIC_RELAXED));
    return true;
}

void XLRDriver::free()
{
    os_log(OS_LOG_DEFAULT, "XLRDriver: free (%u live in this process)", __atomic_sub_fetch(&gLiveDrivers, 1, __ATOMIC_RELAXED));
    if (ivars) {
        for (uint32_t i = 0; i < ivars->clientCount; i++) {
            if (ivars->clients[i].subscriber) ivars->clients[i].subscriber->release();
            ivars->clients[i].client->release();
        }
        ivars->pollAction.reset();
        ivars->pollTimer.reset();
        ivars->in.reset();
        ivars->out.reset();
        ivars->transport.reset();
        ivars->resetQueue.reset();
        ivars->device.reset();
        ivars->trustedTeam.reset();
        if (ivars->clientLock) IOLockFree(ivars->clientLock);
    }
    IOSafeDeleteNULL(ivars, XLRDriver_IVars, 1);
    super::free();
}

kern_return_t
IMPL(XLRDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    mach_timebase_info(&ivars->timebase);
    ivars->pollInterval = kPollIntervalMs;

    OSDictionary * properties = nullptr;
    if (CopyProperties(&properties) == kIOReturnSuccess && properties) {
        OSString * team = OSDynamicCast(OSString, properties->getObject("XLRTrustedTeam"));
        if (team && team->getLength() > 0) ivars->trustedTeam.reset(team, OSRetain);
        properties->release();
    }
    os_log(OS_LOG_DEFAULT, "XLRDriver: hardware-risk commands %{public}s", ivars->trustedTeam
               ? "allowed for clients signed by this driver's team" : "refused for every client (no team set)");

    IOUSBHostDevice * device = OSDynamicCast(IOUSBHostDevice, provider);
    if (!device) return kIOReturnNoDevice;
    ivars->device.reset(device, OSRetain);

    const IOUSBDeviceDescriptor * descriptor = device->CopyDeviceDescriptor();
    uint16_t product = descriptor ? descriptor->idProduct : 0;
    if (descriptor) IOUSBHostFreeDescriptor(descriptor);
    ivars->model = product == kMiniProduct ? XLRModelMini : product == kFullProduct ? XLRModelFull : XLRModelUnknown;
    ivars->policyModel = ivars->model == XLRModelFull ? xlr::policy::Model::full : xlr::policy::Model::mini;
    os_log(OS_LOG_DEFAULT, "XLRDriver: v%u starting on product 0x%04x (model %u)", kDriverVersion, product,
           ivars->model);
    // Failing Start lets the next-best driver (Apple's composite driver) take the device.
    if (ivars->model == XLRModelUnknown) return kIOReturnUnsupported;

    ret = device->Open(this, 0, 0);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "XLRDriver: Open 0x%x", ret);
        return ret;
    }
    ivars->opened = true;
    // ADR 0004 (B): the interfaces are registered for Apple's audio driver.
    ret = device->SetConfiguration(kConfiguration, true);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "XLRDriver: SetConfiguration 0x%x", ret);
        device->Close(this, 0);
        ivars->opened = false;
        return ret;
    }

    IODispatchQueue * queue = nullptr;
    ret = IODispatchQueue::Create("Transport", 0, 0, &queue);
    if (ret != kIOReturnSuccess) return ret;
    ivars->transport = OSSharedPtr(queue, OSNoRetain);
    IODispatchQueue * resetQueue = nullptr;
    ret = IODispatchQueue::Create("Reset", 0, 0, &resetQueue);
    if (ret != kIOReturnSuccess) return ret;
    ivars->resetQueue = OSSharedPtr(resetQueue, OSNoRetain);

    IOBufferMemoryDescriptor * buffer = nullptr;
    IOAddressSegment range = {};
    ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOut, kHeaderLength + XLR_MAX_PAYLOAD, 0, &buffer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->out = OSSharedPtr(buffer, OSNoRetain);
    ivars->out->GetAddressRange(&range);
    ivars->outBytes = reinterpret_cast<uint8_t *>(range.address);
    ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionIn, kHeaderLength + XLR_MAX_PAYLOAD, 0, &buffer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->in = OSSharedPtr(buffer, OSNoRetain);
    ivars->in->GetAddressRange(&range);
    ivars->inBytes = reinterpret_cast<uint8_t *>(range.address);

    IOTimerDispatchSource * timer = nullptr;
    ret = IOTimerDispatchSource::Create(queue, &timer);
    if (ret != kIOReturnSuccess) return ret;
    ivars->pollTimer = OSSharedPtr(timer, OSNoRetain);
    OSAction * action = nullptr;
    ret = CreateActionPollTimerFired(0, &action);
    if (ret != kIOReturnSuccess) return ret;
    ivars->pollAction = OSSharedPtr(action, OSNoRetain);
    ret = timer->SetHandler(action);
    if (ret != kIOReturnSuccess) return ret;

    ret = RegisterService();
    if (ret != kIOReturnSuccess) return ret;
    queue->DispatchAsync(^{
        startDevice(this, ivars);
    });
    return kIOReturnSuccess;
}

kern_return_t
IMPL(XLRDriver, Stop)
{
    os_log(OS_LOG_DEFAULT,
           "XLRDriver: Stop: %llu commands sent, %llu rejected, %llu failed; %llu polls, %llu failed; %llu events",
           ivars->commandsSent, ivars->commandsRejected, ivars->commandsFailed, ivars->polls, ivars->pollFailures,
           ivars->events);
    __atomic_store_n(&ivars->stopping, true, __ATOMIC_SEQ_CST);
    // Let synchronous calls already on the transport queue finish first; with
    // `stopping` set, a command's reply wait ends within one poll step.
    for (int waited = 0; __atomic_load_n(&ivars->inFlight, __ATOMIC_SEQ_CST) > 0; waited += 5) {
        if (waited >= 8000) {
            os_log(OS_LOG_DEFAULT, "XLRDriver: Stop: %u calls still on the transport queue after 8 s",
                   __atomic_load_n(&ivars->inFlight, __ATOMIC_ACQUIRE));
            break;
        }
        IOSleep(5);
    }
    // Close only after the timer and the transport queue have finished, so no
    // request runs on a closed session and free() can't release them early.
    auto finish = ^{
        if (ivars->opened) {
            kern_return_t closed = ivars->device->Close(this, 0);
            os_log(OS_LOG_DEFAULT, "XLRDriver: Close 0x%x", closed);
            ivars->opened = false;
        }
        // The timer holds its action and the action holds this driver: release
        // them here, or the driver is never freed and its process outlives the
        // device (seen after re-enumerations in H3, v3-v5).
        ivars->pollTimer.reset();
        ivars->pollAction.reset();
        Stop(provider, SUPERDISPATCH);
    };
    auto cancelTransport = ^{
        if (ivars->transport) ivars->transport->Cancel(finish);
        else finish();
    };
    if (ivars->pollTimer) ivars->pollTimer->Cancel(cancelTransport);
    else cancelTransport();
    return kIOReturnSuccess;
}

kern_return_t
IMPL(XLRDriver, NewUserClient)
{
    if (type != XLR_USER_CLIENT_TYPE) return kIOReturnBadArgument;
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "XLRDriverUserClientProperties", &client);
    if (ret != kIOReturnSuccess) return ret;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

void
IMPL(XLRDriver, PollTimerFired)
{
    if (stopping(ivars) || ivars->state != XLRDriverStateReady) return;
    ivars->polls++;
    uint8_t state[kInputStateLength];
    uint32_t attempts = 0;
    Outcome outcome = transact(this, ivars, kInputStateCategory, 0, nullptr, 0, kInputStateLength, true, state,
                               &attempts);
    if (outcome.ok()) {
        if (ivars->consecutivePollFailures >= kSlowAfterFailures)
            os_log(OS_LOG_DEFAULT, "XLRDriver: input-state poll recovered after %llu failures",
                   ivars->consecutivePollFailures);
        ivars->consecutivePollFailures = 0;
        ivars->pollInterval = kPollIntervalMs;
        if (__builtin_memcmp(state, ivars->inputState, kInputStateLength) != 0) {
            __builtin_memcpy(ivars->inputState, state, kInputStateLength);
            postInputState(ivars);
        }
    } else if (outcome.error != XLRTransportErrorStopping) {
        ivars->pollFailures++;
        uint64_t failures = ++ivars->consecutivePollFailures;
        if (failures <= 3 || failures % 100 == 0)
            os_log(OS_LOG_DEFAULT, "XLRDriver: input-state poll failed (%llu in a row): error %u, 0x%x, status %u",
                   failures, outcome.error, outcome.ioReturn, outcome.dcpStatus);
        if (failures == kSlowAfterFailures) {
            ivars->pollInterval = kSlowPollIntervalMs;
            os_log(OS_LOG_DEFAULT, "XLRDriver: polling slowed to %u ms", kSlowPollIntervalMs);
        }
    }
    if (!stopping(ivars))
        ivars->pollTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime,
                                     mach_absolute_time() + ticksForMs(ivars, ivars->pollInterval), 0);
}

kern_return_t XLRDriver::AttachClient(IOUserClient * client)
{
    kern_return_t ret = kIOReturnSuccess;
    IOLockLock(ivars->clientLock);
    if (ivars->clientCount == kMaxClients) {
        ret = kIOReturnNoResources;
    } else {
        client->retain();
        ivars->clients[ivars->clientCount++] = { client, nullptr };
    }
    IOLockUnlock(ivars->clientLock);
    return ret;
}

void XLRDriver::DetachClient(IOUserClient * client)
{
    IOLockLock(ivars->clientLock);
    for (uint32_t i = 0; i < ivars->clientCount; i++) {
        if (ivars->clients[i].client != client) continue;
        if (ivars->clients[i].subscriber) ivars->clients[i].subscriber->release();
        client->release();
        ivars->clients[i] = ivars->clients[--ivars->clientCount];
        break;
    }
    IOLockUnlock(ivars->clientLock);
}

void XLRDriver::SetSubscriber(IOUserClient * client, OSAction * completion)
{
    bool found = false;
    IOLockLock(ivars->clientLock);
    for (uint32_t i = 0; i < ivars->clientCount; i++) {
        if (ivars->clients[i].client != client) continue;
        completion->retain();
        if (ivars->clients[i].subscriber) ivars->clients[i].subscriber->release();
        ivars->clients[i].subscriber = completion;
        found = true;
        break;
    }
    IOLockUnlock(ivars->clientLock);
    if (!found || stopping(ivars)) return;
    // A new subscriber gets the current state at once, read on the transport
    // queue where it is written. Asynchronous: a cancelled queue drops it.
    client->retain();
    completion->retain();
    ivars->transport->DispatchAsync(^{
        IOUserClientAsyncArgumentsArray data = {};
        data[0] = XLREventKindDriverState;
        data[1] = ivars->events;
        data[2] = ivars->state;
        data[3] = ivars->startFailure;
        client->AsyncCompletion(completion, kIOReturnSuccess, data, XLR_EVENT_VALUE_COUNT);
        if (ivars->haveInputState) {
            data[0] = XLREventKindInputState;
            data[2] = le64(ivars->inputState, 8);
            data[3] = le64(ivars->inputState + 8, 4);
            client->AsyncCompletion(completion, kIOReturnSuccess, data, XLR_EVENT_VALUE_COUNT);
        }
        completion->release();
        client->release();
    });
}

kern_return_t XLRDriver::CopyInfo(OSData ** info)
{
    __block XLRDriverInfo result = {};
    if (!enterTransport(ivars)) return kIOReturnNotReady;
    ivars->transport->DispatchSync(^{
        result.abiVersion = XLR_DRIVER_ABI_VERSION;
        result.driverVersion = kDriverVersion;
        result.state = ivars->state;
        result.startFailure = ivars->startFailure;
        result.failureReturn = uint32_t(ivars->failureReturn);
        result.startError = ivars->startError;
        result.startDcpStatus = ivars->startDcpStatus;
        result.model = ivars->model;
        result.dcpVersion = ivars->dcpVersion;
        result.maxPayload = ivars->maxPayload;
        result.firmware[0] = ivars->firmware.major;
        result.firmware[1] = ivars->firmware.minor;
        result.firmware[2] = ivars->firmware.patch;
        result.firmware[3] = ivars->firmware.build;
        __builtin_memcpy(result.versions, ivars->versions, sizeof result.versions);
        result.writeTier = kWriteTier;
        result.pollIntervalMs = ivars->pollInterval;
        result.commandsSent = ivars->commandsSent;
        result.commandsRejected = ivars->commandsRejected;
        result.commandsFailed = ivars->commandsFailed;
        result.polls = ivars->polls;
        result.pollFailures = ivars->pollFailures;
        result.events = ivars->events;
    });
    leaveTransport(ivars);
    *info = OSData::withBytes(&result, sizeof result);
    return *info ? kIOReturnSuccess : kIOReturnNoMemory;
}

kern_return_t XLRDriver::Reenumerate()
{
    if (stopping(ivars)) return kIOReturnNotReady;
    OSSharedPtr<IOUSBHostDevice> device = ivars->device;
    os_log(OS_LOG_DEFAULT, "XLRDriver: re-enumeration requested");
    ivars->resetQueue->DispatchAsync(^{
        kern_return_t ret = device->Reset();
        os_log(OS_LOG_DEFAULT, "XLRDriver: Reset 0x%x", ret);
    });
    return kIOReturnSuccess;
}

bool XLRDriver::ClientIsTrusted(OSDictionary * entitlements)
{
    if (!entitlements || !ivars->trustedTeam) return false;
    // A restricted entitlement: only binaries signed through the team's
    // provisioning profiles can carry it (ADR 0003 consequence 2).
    OSString * team = OSDynamicCast(OSString, entitlements->getObject("com.apple.developer.team-identifier"));
    return team && team->isEqualTo(ivars->trustedTeam.get());
}

kern_return_t XLRDriver::ExecuteCommand(OSData * request, OSData ** reply, bool trustedClient)
{
    static_assert(sizeof(XLRCommandReplyHeader) == 24, "ABI");
    uint8_t storage[sizeof(XLRCommandReplyHeader) + XLR_MAX_PAYLOAD];
    uint8_t * buffer = storage; // blocks can't capture arrays
    __block uint32_t replyLength = sizeof(XLRCommandReplyHeader);
    const uint8_t * bytes = static_cast<const uint8_t *>(request->getBytesNoCopy());
    size_t length = request->getLength();

    if (!enterTransport(ivars)) {
        fillReply(buffer, XLRCommandResultNotReady, XLRRejectNone, nullptr, 0);
        *reply = OSData::withBytes(buffer, replyLength);
        return *reply ? kIOReturnSuccess : kIOReturnNoMemory;
    }
    ivars->transport->DispatchSync(^{
        XLRCommandHeader header = {};
        if (length < sizeof header) {
            fillReply(buffer, XLRCommandResultRejected, XLRRejectMalformed, nullptr, 0);
            return;
        }
        __builtin_memcpy(&header, bytes, sizeof header);
        const uint8_t * payload = bytes + sizeof header;
        uint32_t limit = ivars->maxPayload ? ivars->maxPayload : XLR_MAX_PAYLOAD;
        if (sizeof header + header.payloadLength != length || header.payloadLength > limit) {
            ivars->commandsRejected++;
            fillReply(buffer, XLRCommandResultRejected, XLRRejectMalformed, nullptr, 0);
            return;
        }
        if (ivars->state != XLRDriverStateReady || stopping(ivars)) {
            fillReply(buffer, XLRCommandResultNotReady, XLRRejectNone, nullptr, 0);
            return;
        }
        auto decision = xlr::policy::evaluate(header.category, header.index, payload, header.payloadLength,
                                              ivars->policyModel, ivars->firmware, trustedClient);
        bool write = decision.commandClass == xlr::policy::Class::write;
        uint32_t rejected = decision.verdict != xlr::policy::Verdict::allow ? uint32_t(decision.verdict)
                          : write && decision.tier > kWriteTier ? uint32_t(XLRRejectWritesDisabled)
                                                                : uint32_t(XLRRejectNone);
        if (rejected != XLRRejectNone) {
            ivars->commandsRejected++;
            os_log(OS_LOG_DEFAULT, "XLRDriver: rejected 0x%03x:%u, %u bytes: reason %u", header.category,
                   header.index, header.payloadLength, rejected);
            fillReply(buffer, XLRCommandResultRejected, rejected, nullptr, 0);
            return;
        }
        uint32_t attempts = 0;
        ivars->commandsSent++;
        Outcome outcome = transact(this, ivars, header.category, header.index, payload, header.payloadLength,
                                   decision.replyLength, decision.replyExact, buffer + sizeof(XLRCommandReplyHeader),
                                   &attempts);
        if (!outcome.ok()) {
            ivars->commandsFailed++;
            os_log(OS_LOG_DEFAULT, "XLRDriver: 0x%03x:%u failed: error %u, 0x%x, status %u, attempts %u",
                   header.category, header.index, outcome.error, outcome.ioReturn, outcome.dcpStatus, attempts);
            outcome.payloadLength = 0;
            fillReply(buffer, XLRCommandResultFailed, outcome.error, &outcome, attempts);
            return;
        }
        // Payloads are never logged: 0x80F:1 is device identity.
        if (write)
            os_log(OS_LOG_DEFAULT, "XLRDriver: wrote 0x%03x:%u, %u bytes (tier %u, attempts %u)", header.category,
                   header.index, header.payloadLength, decision.tier, attempts);
        fillReply(buffer, XLRCommandResultOK, XLRRejectNone, &outcome, attempts);
        replyLength += outcome.payloadLength;
    });
    leaveTransport(ivars);
    *reply = OSData::withBytes(buffer, replyLength);
    return *reply ? kIOReturnSuccess : kIOReturnNoMemory;
}
