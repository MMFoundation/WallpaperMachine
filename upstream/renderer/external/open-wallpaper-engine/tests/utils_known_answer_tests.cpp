// Pins outputs that other code depends on bit for bit, so replacing the
// implementation behind them cannot move them unnoticed. The expected values
// were captured from the implementations this suite replaced; nothing here
// shells out or reads files.
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "Utils/Random.hpp"

namespace wallpaper
{
namespace
{
// WE_TEST_RANDOM_SEED seeds this engine, and the particle poster comparisons
// replay its sequence, so the same seed has to keep yielding the same values.
TEST(Random, SeededDoubleSequenceIsPinned) {
    Random::seed(12345u);
    const double expected[] = { 0x1.c7c25bcbdbf6ap-1, 0x1.0bb0440a87effp-3, 0x1.45b5b525e2a9bp-5,
                                0x1.a722a2fc68bc2p-1, 0x1.106c844522acep-1, 0x1.e9a1760330eb4p-1,
                                0x1.d90335c7dba9bp-2, 0x1.d8f4351d4e6d4p-1 };
    for (double value : expected) EXPECT_EQ(Random::get(0.0, 1.0), value);
}

TEST(Random, SeededFloatSequenceIsPinned) {
    Random::seed(12345u);
    const float expected[] = { 0x1.dee284p+7f, 0x1.d30be2p+7f, 0x1.26e9a4p+7f, 0x1.de6ca4p+6f,
                               0x1.fe59eep+6f, 0x1.a7db1p+6f,  0x1.055e3ap+7f, 0x1.bfee4ap+7f };
    for (float value : expected) EXPECT_EQ(Random::get(100.0f, 250.0f), value);
}

TEST(Random, SeededIntegerSequenceIsPinned) {
    Random::seed(12345u);
    const std::size_t small[] = { 2, 5, 1, 4, 9, 5, 2, 1, 6, 1, 9, 7 };
    for (std::size_t value : small) EXPECT_EQ(Random::get<std::size_t>(0, 9), value);

    Random::seed(12345u);
    const std::size_t wide[] = { 771445219, 601959910, 285080862, 561383554, 789925285, 170765738 };
    for (std::size_t value : wide) EXPECT_EQ(Random::get<std::size_t>(1, 1000000007ull), value);
}

TEST(Random, ReversedBoundsDrawFromTheSameRange) {
    Random::seed(12345u);
    const double reals[] = { 0x1.d30be1c972e28p+7, 0x1.de6ca3ef15d35p+6, 0x1.a7db0f048659fp+6,
                             0x1.bfee4b7fe55e4p+7 };
    for (double value : reals) EXPECT_EQ(Random::get(250.0, 100.0), value);

    Random::seed(12345u);
    const std::size_t ints[] = { 2, 5, 1, 4, 9, 5 };
    for (std::size_t value : ints) EXPECT_EQ(Random::get<std::size_t>(9, 0), value);
}

TEST(Random, EqualBoundsReturnThatValue) {
    EXPECT_EQ(Random::get(3.5, 3.5), 3.5);
    EXPECT_EQ(Random::get<std::size_t>(7, 7), std::size_t { 7 });
}

// Particle emission draws every type from one stream, so the order of mixed
// draws is part of the contract too.
TEST(Random, MixedDrawsShareOneStream) {
    Random::seed(4242u);
    const double      reals[]  = { 0x1.9dfcc3dca65fcp-1, 0x1.cfabda8ba7f1bp-2, 0x1.425a23ee4121cp-3,
                                   0x1.0743c6910f179p-1 };
    const float       floats[] = { 0x1.367762p+4f, 0x1.9baedap+3f, 0x1.09293p+4f, 0x1.ab46aep+3f };
    const std::size_t ints[]   = { 17, 17, 93, 42 };
    for (int i = 0; i < 4; ++i) {
        EXPECT_EQ(Random::get(0.0, 1.0), reals[i]);
        EXPECT_EQ(Random::get(10.0f, 20.0f), floats[i]);
        EXPECT_EQ(Random::get<std::size_t>(0, 99), ints[i]);
    }
}

TEST(Random, ReseedingRestartsTheSequence) {
    Random::seed(99u);
    std::vector<double> first;
    for (int i = 0; i < 5; ++i) first.push_back(Random::get(0.0, 1.0));
    Random::seed(99u);
    for (double value : first) EXPECT_EQ(Random::get(0.0, 1.0), value);
}

// The stream is per thread: seeding here must not disturb another thread, and
// that thread must not disturb this one.
TEST(Random, EachThreadOwnsItsStream) {
    Random::seed(7u);
    const double expected = Random::get(0.0, 1.0);
    Random::seed(7u);
    std::thread([] {
        Random::seed(1u);
        for (int i = 0; i < 100; ++i) Random::get(0.0, 1.0);
    }).join();
    EXPECT_EQ(Random::get(0.0, 1.0), expected);
}
} // namespace
} // namespace wallpaper
