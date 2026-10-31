// The XLR driver's user-client interface (ADR 0003, option (d)). One source for
// both sides: the dext includes this header, and GoXLRKit imports it as the C
// module XLRDriverABI. Plain C; all fields little-endian (both sides run on the
// same Mac). Bump XLR_DRIVER_ABI_VERSION on any layout or meaning change.

#ifndef XLRDriverABI_h
#define XLRDriverABI_h

#include <stdint.h>

#define XLR_DRIVER_ABI_VERSION 5u

// IOServiceOpen type. coreaudiod's type ('CAHd') is never served by this driver.
#define XLR_USER_CLIENT_TYPE 0x786c7264u /* 'xlrd' */

#define XLR_MAX_PAYLOAD 1024u

enum XLRSelector {
    XLRSelectorInfo = 0,         // structure out: XLRDriverInfo
    XLRSelectorCommand = 1,      // structure in: XLRCommandHeader + payload; out: XLRCommandReplyHeader + payload
    XLRSelectorSubscribe = 2,    // async, no arguments; events arrive as XLR_EVENT_VALUE_COUNT values
    XLRSelectorStreamStatus = 3, // scalar out [0]: XLRStreamOwner
    XLRSelectorReenumerate = 4,  // no arguments; resets the USB device so it re-attaches (ABI 4)
    XLRSelectorClientTrust = 5,  // scalar out [0]: 1 if this client is signed by the driver's team (ABI 5)
};

enum XLRDriverState {
    XLRDriverStateStarting = 0,
    XLRDriverStateReady = 1,
    XLRDriverStateFailed = 2,
};

// Which start step failed (SPEC.md section 7). XLRDriverInfo.failureReturn holds its IOReturn.
enum XLRStartFailure {
    XLRStartFailureNone = 0,
    XLRStartFailureUnknownModel = 1,
    XLRStartFailureOpen = 2,
    XLRStartFailureConfiguration = 3,
    XLRStartFailureGlobalData = 4,
    XLRStartFailureBadMagic = 5,
    XLRStartFailurePayloadLimit = 6,
    XLRStartFailureUninitialised = 7, // the reset STALLed (L-065)
    XLRStartFailureReset = 8,
    XLRStartFailureVersions = 9,
    XLRStartFailureInputState = 10,
};

enum XLRModel {
    XLRModelUnknown = 0,
    XLRModelMini = 1,
    XLRModelFull = 2,
};

enum XLRStreamOwner {
    XLRStreamOwnerApple = 1, // usbaudiod streams (ADR 0004, Phases 4 and 5)
};

typedef struct __attribute__((packed)) {
    uint32_t abiVersion;
    uint32_t driverVersion;
    uint32_t state;         // XLRDriverState
    uint32_t startFailure;  // XLRStartFailure
    uint32_t failureReturn; // IOReturn of the failed step
    uint32_t startError;    // XLRTransportError of the failed step, if it was a command (ABI 2)
    uint32_t startDcpStatus;
    uint32_t model;         // XLRModel
    uint32_t dcpVersion;
    uint32_t maxPayload;
    uint32_t firmware[4];   // major, minor, patch, build (0x80F:0, SPEC.md section 9)
    uint8_t versions[24];   // the raw 0x80F:0 reply payload
    uint32_t writeTier;     // highest Phase 5 risk tier allowed (0: reads only; ABI 3)
    uint32_t pollIntervalMs;
    uint64_t commandsSent;
    uint64_t commandsRejected;
    uint64_t commandsFailed;
    uint64_t polls;
    uint64_t pollFailures;
    uint64_t events;
} XLRDriverInfo;

typedef struct __attribute__((packed)) {
    uint32_t category;
    uint32_t index;
    uint32_t payloadLength; // the payload follows the header
} XLRCommandHeader;

enum XLRCommandResult {
    XLRCommandResultOK = 0,
    XLRCommandResultRejected = 1, // detail: XLRReject; never sent
    XLRCommandResultFailed = 2,   // detail: XLRTransportError
    XLRCommandResultNotReady = 3, // the driver hasn't finished starting, or failed to
};

// The policy verdicts (SPEC.md section 8), then the driver's own refusals.
enum XLRReject {
    XLRRejectNone = 0,
    XLRRejectOpcode = 1,
    XLRRejectIndex = 2,
    XLRRejectFirmware = 3,
    XLRRejectLength = 4,
    XLRRejectValue = 5,
    XLRRejectHardwareRisk = 6,   // a hardware-risk value from a client not signed by the driver's team
    XLRRejectWritesDisabled = 7, // a write above the driver's tier
    XLRRejectMalformed = 8, // header and structure sizes disagree, or the payload is over maxPayload
};

// SPEC.md section 6, the error algebra.
enum XLRTransportError {
    XLRTransportErrorNone = 0,
    XLRTransportErrorTransfer = 1, // ioReturn holds the IOReturn
    XLRTransportErrorStall = 2,
    XLRTransportErrorWaitTimeout = 3,
    XLRTransportErrorReplyTooShort = 4,
    XLRTransportErrorOpcodeMismatch = 5,
    XLRTransportErrorSequenceMismatch = 6,
    XLRTransportErrorLengthMismatch = 7,
    XLRTransportErrorReplyTooLarge = 8,
    XLRTransportErrorDcpStatus = 9, // dcpStatus holds the code
    XLRTransportErrorStopping = 10,
};

typedef struct __attribute__((packed)) {
    uint32_t result;   // XLRCommandResult
    uint32_t detail;   // XLRReject or XLRTransportError
    uint32_t dcpStatus;
    uint32_t ioReturn;
    uint32_t attempts; // 2 when the command was retried after a reset (SPEC.md section 4)
    uint32_t payloadLength; // the reply payload follows the header
} XLRCommandReplyHeader;

// Async events: AsyncCompletion with XLR_EVENT_VALUE_COUNT values.
//   [0] XLREventKind
//   [1] event sequence number (1, 2, ...; per driver instance)
//   input state: [2] bytes 0-7 and [3] bytes 8-11 of the 0x800:0 reply, little-endian
//   driver state: [2] XLRDriverState, [3] XLRStartFailure
#define XLR_EVENT_VALUE_COUNT 4u

enum XLREventKind {
    XLREventKindInputState = 1,
    XLREventKindDriverState = 2,
};

#endif /* XLRDriverABI_h */
