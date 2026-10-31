// Command policy (SPEC.md section 8, default deny). Plain C++; see PolicyTypes.h.

#pragma once

#include "PolicyTypes.h"

namespace xlr::policy {

struct Decision {
    Verdict verdict;
    Class commandClass;    // valid when allowed
    uint8_t tier;          // write risk tier when allowed; 0 for reads
    uint16_t replyLength;  // expected reply payload size
    bool replyExact;       // false: replyLength is a maximum (0x80F:1)
};

// trustedClient: the client is signed by the developer team, so hardware-risk
// values (phantom power) pass this check; every other check still applies, and
// the driver's write tier still decides (the user's decision, SPEC.md section 8).
Decision evaluate(uint32_t category, uint32_t index, const uint8_t * payload, size_t length, Model model,
                  const Firmware & firmware, bool trustedClient = false);

// The reason strings Tests/Vectors/policy.json uses ("opcode", "hardware-risk", ...).
const char * verdictName(Verdict verdict);

} // namespace xlr::policy
