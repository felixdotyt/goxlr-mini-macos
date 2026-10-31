// Command policy evaluator over the generated table. Checks run in the order
// SPEC.md section 8 and Tests/Vectors/check_vectors.py use: category, index,
// firmware gate, length, values. The first failure is the verdict.

#include "Policy.h"
#include "PolicyTable.generated.h"

namespace xlr::policy {
namespace {

using namespace table;

bool inRanges(uint32_t value, const Range * ranges, uint8_t count)
{
    for (uint8_t i = 0; i < count; i++)
        if (value >= ranges[i].lo && value <= ranges[i].hi) return true;
    return false;
}

template <typename T>
bool contains(const T * values, uint8_t count, uint32_t value)
{
    for (uint8_t i = 0; i < count; i++)
        if (values[i] == value) return true;
    return false;
}

bool atLeast(const Firmware & firmware, const uint32_t (&gate)[4])
{
    const uint32_t have[4] = { firmware.major, firmware.minor, firmware.patch, firmware.build };
    for (int i = 0; i < 4; i++)
        if (have[i] != gate[i]) return have[i] > gate[i];
    return true;
}

bool gateOpen(Gate gate, Model model, const Firmware & firmware)
{
    const GateVersions & versions = model == Model::full ? kFullGates : kMiniGates;
    switch (gate) {
    case Gate::none: return true;
    case Gate::animations: return atLeast(firmware, versions.animations);
    case Gate::submix: return atLeast(firmware, versions.submix);
    case Gate::mix2: return atLeast(firmware, versions.mix2);
    }
    return false;
}

uint32_t u32At(const uint8_t * bytes)
{
    return uint32_t(bytes[0]) | uint32_t(bytes[1]) << 8 | uint32_t(bytes[2]) << 16 | uint32_t(bytes[3]) << 24;
}

Decision reject(Verdict verdict)
{
    return { verdict, Class::read, 0, 0, true };
}

Verdict checkValues(const Rule & rule, const uint8_t * payload, size_t length, bool trustedClient)
{
    switch (rule.valueKind) {
    case ValueKind::none:
        return Verdict::allow;
    case ValueKind::keyPairs:
        for (size_t offset = 0; offset + 8 <= length; offset += 8) {
            uint32_t key = u32At(payload + offset), value = u32At(payload + offset + 4);
            if (!inRanges(key, rule.keys, rule.keyCount)) return Verdict::value;
            if (rule.hasSpecialKey && key == rule.specialKey) {
                if (contains(rule.specialRisk, rule.specialRiskCount, value)) {
                    if (!trustedClient) return Verdict::hardwareRisk;
                    continue; // allowed for a trusted client; the remaining pairs are still checked
                }
                if (!contains(rule.specialAllowed, rule.specialAllowedCount, value)) return Verdict::value;
            }
        }
        return Verdict::allow;
    case ValueKind::routing:
        for (size_t i = 0; i < length; i++) {
            bool ok = i == length - 1 ? contains(rule.last, rule.lastCount, payload[i])
                    : i % 2           ? contains(rule.odd, rule.oddCount, payload[i])
                                      : contains(rule.even, rule.evenCount, payload[i]);
            if (!ok) return Verdict::value;
        }
        return Verdict::allow;
    case ValueKind::u32Max:
        return length >= 4 && u32At(payload) <= rule.maxValue ? Verdict::allow : Verdict::value;
    case ValueKind::bytesMax:
        for (size_t i = 0; i < length; i++)
            if (payload[i] > rule.maxValue) return Verdict::value;
        return Verdict::allow;
    case ValueKind::bytesIn:
        for (size_t i = 0; i < length; i++)
            if (!contains(rule.allowedBytes, rule.allowedByteCount, payload[i])) return Verdict::value;
        return Verdict::allow;
    }
    return Verdict::value;
}

} // namespace

Decision evaluate(uint32_t category, uint32_t index, const uint8_t * payload, size_t length, Model model,
                  const Firmware & firmware, bool trustedClient)
{
    const Rule * rule = nullptr;
    for (const Rule & candidate : kRules)
        if (candidate.category == category) rule = &candidate;
    if (!rule) return reject(Verdict::opcode);

    Gate gate = rule->commandGate;
    if (inRanges(index, rule->gatedIndices, rule->gatedIndexCount)) {
        if (gate == Gate::none) gate = rule->indexGate;
    } else if (!inRanges(index, rule->indices, rule->indexCount)) {
        return reject(Verdict::index);
    }
    if (!gateOpen(gate, model, firmware)) return reject(Verdict::firmware);

    switch (rule->lengthKind) {
    case LengthKind::exact:
        if (length != rule->length) return reject(Verdict::length);
        break;
    case LengthKind::pairs:
        if (length == 0 || length % 8) return reject(Verdict::length);
        break;
    case LengthKind::gated: {
        uint16_t expected = gateOpen(rule->lengthGate, model, firmware) ? rule->lengthAtGate : rule->lengthBelowGate;
        if (length != expected) return reject(Verdict::length);
        break;
    }
    }

    Verdict verdict = checkValues(*rule, payload, length, trustedClient);
    if (verdict != Verdict::allow) return reject(verdict);

    Decision decision = { Verdict::allow, rule->commandClass, rule->tier, rule->reply, true };
    if (rule->hasReplyOverride && index == rule->replyOverrideIndex) {
        decision.replyLength = rule->replyOverrideMax;
        decision.replyExact = false;
    }
    if (inRanges(index, rule->identityIndices, rule->identityIndexCount)) decision.commandClass = Class::identity;
    return decision;
}

const char * verdictName(Verdict verdict)
{
    switch (verdict) {
    case Verdict::allow: return "allow";
    case Verdict::opcode: return "opcode";
    case Verdict::index: return "index";
    case Verdict::firmware: return "firmware";
    case Verdict::length: return "length";
    case Verdict::value: return "value";
    case Verdict::hardwareRisk: return "hardware-risk";
    }
    return "unknown";
}

} // namespace xlr::policy
