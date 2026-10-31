// Host harness for the dext's policy evaluator (Driver/XLRDriver/Policy.cpp).
// Reads one command per line: category index model major minor patch build payload-hex|- [trusted]
// and prints the verdict name. Driven by check_policy.py.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "Policy.h"

int main()
{
    char line[8192];
    while (std::fgets(line, sizeof line, stdin)) {
        unsigned category = 0, index = 0, major = 0, minor = 0, patch = 0, build = 0;
        char model[16] = {}, hex[8000] = {}, trust[16] = {};
        int fields = std::sscanf(line, "%u %u %15s %u %u %u %u %7999s %15s", &category, &index, model, &major, &minor,
                                 &patch, &build, hex, trust);
        if (fields < 8) {
            std::printf("bad-input\n");
            continue;
        }
        std::vector<uint8_t> payload;
        if (std::strcmp(hex, "-") != 0)
            for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) payload.push_back(uint8_t(std::stoul(std::string(hex + i, 2), nullptr, 16)));
        xlr::policy::Firmware firmware = { major, minor, patch, build };
        auto m = std::strcmp(model, "full") == 0 ? xlr::policy::Model::full : xlr::policy::Model::mini;
        bool trusted = fields == 9 && std::strcmp(trust, "trusted") == 0;
        auto decision = xlr::policy::evaluate(category, index, payload.data(), payload.size(), m, firmware, trusted);
        std::printf("%s\n", xlr::policy::verdictName(decision.verdict));
    }
    return 0;
}
