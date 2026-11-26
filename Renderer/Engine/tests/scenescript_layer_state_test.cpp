#include "Runtime/SceneLayerState.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <limits>

namespace wallpaper {
namespace {

struct SwitchScene {
    Scene scene;
    std::unique_ptr<SceneRuntimeContext> runtime = CreateSceneRuntimeContext(
        SceneRuntimeBootstrap { .canvas_width = 200, .canvas_height = 100 });
    std::shared_ptr<SceneMaterial> first = std::make_shared<SceneMaterial>();
    std::shared_ptr<SceneMaterial> second = std::make_shared<SceneMaterial>();

    std::shared_ptr<SceneNode> layer(std::string key, int32_t id) {
        auto node = std::make_shared<SceneNode>();
        node->SetName(key);
        node->ID() = id;
        runtime->RegisterNode(key, node.get());
        runtime->RegisterLayerId(id, key);
        return node;
    }

    explicit SwitchScene(std::string prefix) {
        runtime->AttachScene(&scene);
        auto button = layer("button", 1);
        runtime->SetNodeTranslate("button", linalg::Vector3f(100, 50, 0));
        runtime->RegisterNodeSize("button", { 100, 60 });
        scene.sceneGraph->AppendChild(button);
        for (const auto& [id, material] : { std::pair { 10, first }, std::pair { 20, second } }) {
            std::string key = prefix + std::to_string(id);
            scene.sceneGraph->AppendChild(layer(key, id));
            runtime->RegisterNodeAlpha(key, material, 1);
        }
        scene.sceneGraph->AppendChild(layer("animated", 30));
        runtime->RegisterSceneScript(R"JS(
            export function update() { thisLayer.visible = !thisLayer.visible; }
        )JS", "animated");
        runtime->RegisterNodeVisibility("button", button.get(),
            ResolveBoolSetting(*runtime, {{"value", true}, {"script", R"JS(
                let source, destination, remaining = 0;
                export function init() {
                    source = thisScene.getLayerByID(10);
                    destination = thisScene.getLayerByID(20);
                    source.visible = true; source.alpha = 1;
                    destination.visible = false; destination.alpha = 0;
                }
                export function cursorClick() {
                    destination.visible = true;
                    remaining = 2;
                }
                export function update() {
                    if (!remaining) return;
                    remaining--;
                    source.alpha = remaining / 2;
                    destination.alpha = 1 - source.alpha;
                    if (!remaining) {
                        source.visible = false;
                        [source, destination] = [destination, source];
                    }
                }
            )JS"}}, "button"));
        runtime->Tick(1.0 / 60.0);
    }

    void click() {
        runtime->SetCursorWorldPosition(linalg::Vector3f(100, 50, 0));
        runtime->SetCursorEnter(true);
        runtime->SetCursorButtons(0, 1, 1);
        runtime->DispatchCursorFrameEvents(false);
        runtime->SetCursorButtons(0, 0, 0);
    }
};

TEST(InteractiveLayerState, ASettledSwitchAndSwitchBackReachAnIndependentSceneByAuthoredId) {
    SwitchScene desktop("desktop-");
    desktop.click();
    desktop.runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(desktop.runtime->NodeVisible("desktop-10"));
    EXPECT_EQ(desktop.runtime->NodeAlpha("desktop-20"), 0.5f);
    desktop.runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(desktop.runtime->NodeVisible("desktop-10"));
    EXPECT_EQ(desktop.runtime->NodeAlpha("desktop-20"), 1.0f);

    SwitchScene lock("extension-");
    EXPECT_TRUE(lock.runtime->NodeVisible("extension-10"));
    EXPECT_FALSE(lock.runtime->NodeVisible("extension-20"));
    EXPECT_EQ(lock.runtime->NodeAlpha("extension-20"), 0.0f);
    const bool animated = lock.runtime->NodeVisible("animated");
    const auto snapshot = SceneLayerState::Parse(desktop.runtime->CaptureLayerState());
    ASSERT_TRUE(snapshot);
    ASSERT_EQ(snapshot->layers().size(), 2u);
    EXPECT_EQ(lock.runtime->ApplyLayerState(*snapshot), true);
    lock.runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(lock.runtime->NodeVisible("extension-10"));
    EXPECT_TRUE(lock.runtime->NodeVisible("extension-20"));
    EXPECT_EQ(lock.first->customShader.constValues.at("g_UserAlpha")[0], 0.0f);
    EXPECT_EQ(lock.second->customShader.constValues.at("g_UserAlpha")[0], 1.0f);
    EXPECT_NE(lock.runtime->NodeVisible("animated"), animated);
    EXPECT_EQ(lock.runtime->ApplyLayerState(*snapshot), false);

    desktop.click();
    desktop.runtime->Tick(1.0 / 60.0);
    desktop.runtime->Tick(1.0 / 60.0);
    const auto restored = SceneLayerState::Parse(desktop.runtime->CaptureLayerState());
    ASSERT_TRUE(restored);
    EXPECT_EQ(lock.runtime->ApplyLayerState(*restored), true);
    EXPECT_TRUE(lock.runtime->NodeVisible("extension-10"));
    EXPECT_FALSE(lock.runtime->NodeVisible("extension-20"));
    EXPECT_EQ(lock.first->customShader.constValues.at("g_UserAlpha")[0], 1.0f);
    EXPECT_EQ(lock.second->customShader.constValues.at("g_UserAlpha")[0], 0.0f);
    EXPECT_EQ(desktop.runtime->scriptErrorCount(), 0u);
    EXPECT_EQ(lock.runtime->scriptErrorCount(), 0u);
}

TEST(InteractiveLayerState, AGeneratedIdAnUnknownIdOrAnUnboundAlphaRejectsTheWholeBatch) {
    SwitchScene scene("item");
    int32_t generatedId = 0;
    scene.runtime->SetTextLayerFactory([&](const std::string&, int32_t id) {
        generatedId = id;
        return scene.layer("generated", id);
    });
    ASSERT_EQ(scene.runtime->CreateTextLayer("{}", "button"), "generated");
    scene.runtime->RegisterSceneScript(R"JS(
        export function cursorClick() { thisScene.getLayer("generated").visible = false; }
    )JS", "button");
    scene.runtime->DispatchCursorClick();
    scene.runtime->Tick(1.0 / 60.0);
    scene.runtime->Tick(1.0 / 60.0);
    ASSERT_FALSE(scene.runtime->NodeVisible("generated"));
    const auto capture = SceneLayerState::Parse(scene.runtime->CaptureLayerState());
    ASSERT_TRUE(capture);
    EXPECT_EQ(capture->layers().size(), 2u);
    for (int32_t id : { generatedId, 404, 30 }) {
        const auto payload = SceneLayerState::Parse(
            R"({"version":1,"layers":[[10,true,1],[)" + std::to_string(id) + ",true,1]]}");
        ASSERT_TRUE(payload);
        EXPECT_EQ(scene.runtime->ApplyLayerState(*payload), std::nullopt);
        EXPECT_FALSE(scene.runtime->NodeVisible("item10"));
        EXPECT_EQ(scene.runtime->NodeAlpha("item10"), 0.0f);
    }
    scene.runtime->SetNodeAlpha("item20", std::numeric_limits<float>::infinity());
    const auto bad_target = SceneLayerState::Parse(R"({"version":1,"layers":[[10,true,1],[20,true,0]]})");
    ASSERT_TRUE(bad_target);
    EXPECT_EQ(scene.runtime->ApplyLayerState(*bad_target), std::nullopt);
    EXPECT_FALSE(scene.runtime->NodeVisible("item10"));
    EXPECT_EQ(scene.runtime->NodeAlpha("item10"), 0.0f);
}

TEST(InteractiveLayerState, AnUntouchedDesktopReleasesTheRetainedHandoffWithoutRevertingLocalWrites) {
    SwitchScene clicked("desktop"), untouched("fresh"), target("lock");
    clicked.click();
    clicked.runtime->Tick(1.0 / 60.0);
    clicked.runtime->Tick(1.0 / 60.0);
    const auto switched = SceneLayerState::Parse(clicked.runtime->CaptureLayerState());
    const auto empty = SceneLayerState::Parse(untouched.runtime->CaptureLayerState());
    ASSERT_TRUE(switched);
    ASSERT_TRUE(empty);
    ASSERT_TRUE(empty->layers().empty());
    ASSERT_EQ(target.runtime->ApplyLayerState(*switched), true);
    const auto unknown = SceneLayerState::Parse(R"({"version":1,"layers":[[404,true,null]]})");
    ASSERT_TRUE(unknown);
    ASSERT_EQ(target.runtime->ApplyLayerState(*unknown), std::nullopt);
    EXPECT_FALSE(target.runtime->NodeVisible("lock10"));
    EXPECT_EQ(target.runtime->ApplyLayerState(*empty), true);
    EXPECT_TRUE(target.runtime->NodeVisible("lock10"));
    EXPECT_FALSE(target.runtime->NodeVisible("lock20"));
    EXPECT_EQ(target.runtime->NodeAlpha("lock10"), 1.0f);
    EXPECT_EQ(target.runtime->NodeAlpha("lock20"), 0.0f);

    ASSERT_EQ(target.runtime->ApplyLayerState(*switched), true);
    const auto partial = SceneLayerState::Parse(R"({"version":1,"layers":[[10,null,0.5]]})");
    ASSERT_TRUE(partial);
    EXPECT_EQ(target.runtime->ApplyLayerState(*partial), true);
    EXPECT_TRUE(target.runtime->NodeVisible("lock10"));
    EXPECT_FALSE(target.runtime->NodeVisible("lock20"));
    EXPECT_EQ(target.runtime->NodeAlpha("lock10"), 0.5f);
    EXPECT_EQ(target.runtime->NodeAlpha("lock20"), 0.0f);
    target.runtime->SetNodeAlpha("lock10", 0.75f);
    EXPECT_EQ(target.runtime->ApplyLayerState(*empty), false);
    EXPECT_EQ(target.runtime->NodeAlpha("lock10"), 0.75f);
}

TEST(InteractiveLayerState, RejectsMalformedFieldsAndHonorsByteAndCountBoundaries) {
    for (const char* text : {"{", "null", "{}", R"({"version":2,"layers":[]})",
                             R"({"version":1,"layers":[],"other":1})",
                             R"({"version":2,"version":1,"layers":[]})"}) {
        EXPECT_FALSE(SceneLayerState::Parse(text)) << text;
    }
    for (const char* layer : {"[1]", R"(["1",true,0])", "[0,true,0]", "[1.5,true,0]",
                              "[2147483648,true,0]", "[1,null,null]", "[1,2,null]",
                              R"([1,false,"NaN"])", "[1,false,1e400]", "[1,false,1e100]",
                              "[1,true,0],[1,false,0]" }) {
        EXPECT_FALSE(SceneLayerState::Parse(std::string(R"({"version":1,"layers":[)") + layer + "]}"));
    }
    std::string padded = R"({"version":1,"layers":[[-1,null,0.25],[12,false,null]]})";
    padded.resize(64 * 1024, ' ');
    EXPECT_TRUE(SceneLayerState::Parse(padded));
    padded.push_back(' ');
    EXPECT_FALSE(SceneLayerState::Parse(padded));
    const auto empty = std::string(SceneLayerState::EmptyJson);
    EXPECT_FALSE(SceneLayerState::Parse(empty + '\0' + "trailing"));

    nlohmann::json rows = nlohmann::json::array();
    for (int id = 1; id <= 2048; ++id) rows.push_back({ id, true, nullptr });
    EXPECT_TRUE(SceneLayerState::Parse(nlohmann::json({{"version", 1}, {"layers", rows}}).dump()));
    rows.push_back({ 2049, true, nullptr });
    EXPECT_FALSE(SceneLayerState::Parse(nlohmann::json({{"version", 1}, {"layers", rows}}).dump()));
}

TEST(InteractiveLayerState, AnOversizedOrNonfiniteCaptureCannotReleaseARetainedPicture) {
    SwitchScene scene("item");
    auto material = std::make_shared<SceneMaterial>();
    for (int id = 1000; id < 3048; ++id) {
        const auto key = std::to_string(id);
        scene.scene.sceneGraph->AppendChild(scene.layer(key, id));
        scene.runtime->SetNodeVisible(key, true, true);
        scene.runtime->RegisterNodeAlpha(key, material, 1.0f);
    }
    const auto limit = SceneLayerState::Parse(scene.runtime->CaptureLayerState());
    ASSERT_TRUE(limit);
    EXPECT_EQ(limit->layers().size(), 2048u);
    for (int id = 1000; id < 3048; ++id)
        scene.runtime->SetNodeAlpha(std::to_string(id), std::numeric_limits<float>::max(), true);
    EXPECT_TRUE(scene.runtime->CaptureLayerState().empty());
    for (int id = 1000; id < 3048; ++id) scene.runtime->SetNodeAlpha(std::to_string(id), 1);
    EXPECT_FALSE(scene.runtime->CaptureLayerState().empty());
    scene.runtime->SetNodeAlpha("1000", std::numeric_limits<float>::infinity());
    EXPECT_TRUE(scene.runtime->CaptureLayerState().empty());
    scene.runtime->SetNodeAlpha("1000", 1);
    scene.scene.sceneGraph->AppendChild(scene.layer("extra", 3048));
    scene.runtime->SetNodeVisible("extra", false, true);
    EXPECT_TRUE(scene.runtime->CaptureLayerState().empty());
}

TEST(InteractiveLayerState, AButtonListenerCanCompleteItsSwitchOnALaterUpdate) {
    SwitchScene scene("item");
    scene.runtime->RegisterSceneScript(R"JS(
        let switchNext = false;
        engine.on('cursorDown', function() { switchNext = true; });
        export function update() {
            if (!switchNext) return;
            switchNext = false;
            thisScene.getLayerByID(10).alpha = 0.375;
        }
    )JS", "button");
    scene.runtime->DispatchCursorDown();
    scene.runtime->Tick(1.0 / 60.0);
    const auto capture = SceneLayerState::Parse(scene.runtime->CaptureLayerState());
    ASSERT_TRUE(capture);
    ASSERT_EQ(capture->layers().size(), 1u);
    EXPECT_EQ(capture->layers()[0].id, 10);
    EXPECT_EQ(capture->layers()[0].alpha, 0.375f);
    EXPECT_FALSE(capture->layers()[0].visible.has_value());
}

} // namespace
} // namespace wallpaper
