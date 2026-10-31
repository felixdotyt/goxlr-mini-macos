// Types of the generated command-policy table (PolicyTable.generated.h).
// Plain C++ with no DriverKit dependency, so the host policy test compiles it too.

#pragma once

#include <stddef.h>
#include <stdint.h>

namespace xlr::policy {

enum class Model : uint8_t { mini, full };

// The checker's categories in Tests/Vectors/policy.json, in check order.
enum class Verdict : uint8_t { allow, opcode, index, firmware, length, value, hardwareRisk };

enum class Class : uint8_t { read, identity, write };

struct Firmware {
    uint32_t major, minor, patch, build;
};

namespace table {

struct Range {
    uint32_t lo, hi;
};

enum class Gate : uint8_t { none, animations, submix, mix2 };
enum class LengthKind : uint8_t { exact, pairs, gated };
enum class ValueKind : uint8_t { none, keyPairs, routing, u32Max, bytesMax, bytesIn };

struct GateVersions {
    uint32_t animations[4], submix[4], mix2[4];
};

struct Rule {
    uint32_t category;
    const Range * indices = nullptr;
    uint8_t indexCount = 0;
    const Range * gatedIndices = nullptr;
    uint8_t gatedIndexCount = 0;
    Gate indexGate = Gate::none;
    Gate commandGate = Gate::none;
    LengthKind lengthKind = LengthKind::exact;
    uint16_t length = 0;
    Gate lengthGate = Gate::none;
    uint16_t lengthAtGate = 0;
    uint16_t lengthBelowGate = 0;
    ValueKind valueKind = ValueKind::none;
    const Range * keys = nullptr;
    uint8_t keyCount = 0;
    bool hasSpecialKey = false;
    uint32_t specialKey = 0;
    const uint32_t * specialAllowed = nullptr;
    uint8_t specialAllowedCount = 0;
    const uint32_t * specialRisk = nullptr;
    uint8_t specialRiskCount = 0;
    const uint8_t * even = nullptr;
    uint8_t evenCount = 0;
    const uint8_t * odd = nullptr;
    uint8_t oddCount = 0;
    const uint8_t * last = nullptr;
    uint8_t lastCount = 0;
    uint32_t maxValue = 0;
    const uint8_t * allowedBytes = nullptr;
    uint8_t allowedByteCount = 0;
    uint16_t reply = 0;
    bool hasReplyOverride = false;
    uint32_t replyOverrideIndex = 0;
    uint16_t replyOverrideMax = 0;
    Class commandClass = Class::read;
    uint8_t tier = 0; // write risk tier (PROMPT.md Phase 5); 0 for reads
    const Range * identityIndices = nullptr;
    uint8_t identityIndexCount = 0;
};

} // namespace table
} // namespace xlr::policy
