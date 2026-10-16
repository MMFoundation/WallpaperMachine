#include "Utils/Sha.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cstdint>
#include <limits>

// The digest names caches and keys them; it is not a security boundary. The
// SDK does not mark CC_SHA1 deprecated, so no warning needs silencing here.
std::string utils::genSha1(std::span<const char> in) {
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    // CC_LONG is 32 bits wide, so a payload past 4 GiB goes in several updates.
    constexpr std::size_t kMaxChunk = std::numeric_limits<CC_LONG>::max();
    const char*           data      = in.data();
    for (std::size_t left = in.size(); left > 0;) {
        const std::size_t chunk = std::min(left, kMaxChunk);
        CC_SHA1_Update(&context, data, static_cast<CC_LONG>(chunk));
        data += chunk;
        left -= chunk;
    }
    std::uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);

    static constexpr char kHex[] = "0123456789abcdef";
    std::string           hex(SHA1_LEN, '0');
    for (std::size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; ++i) {
        hex[2 * i]     = kHex[digest[i] >> 4];
        hex[2 * i + 1] = kHex[digest[i] & 0x0f];
    }
    return hex;
}
