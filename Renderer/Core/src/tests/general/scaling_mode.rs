//! "Fit with blurred backdrop" travels from a scene descriptor to the engine's
//! scaling-mode property without disturbing the other modes.
use crate::{
    DisplayDesc,
    owe::backend::scaling_mode_property_value,
    project::{ScalingMode, SceneDesc, SceneTemplate},
};

#[test]
fn fit_with_blurred_backdrop_reaches_the_engine_as_mode_four() {
    assert_eq!(scaling_mode_property_value(ScalingMode::FitBlurred), 4);
}

#[test]
fn fill_with_blurred_backdrop_reaches_the_engine_as_mode_five() {
    assert_eq!(scaling_mode_property_value(ScalingMode::FillBlurred), 5);
}

#[test]
fn the_other_scaling_modes_keep_their_engine_values() {
    let values = [
        ScalingMode::None,
        ScalingMode::Stretch,
        ScalingMode::Fit,
        ScalingMode::Fill,
    ]
    .map(scaling_mode_property_value);
    assert_eq!(values, [0, 1, 2, 3]);
}

#[test]
fn a_scene_keeps_the_blurred_modes_through_its_template() {
    let display = DisplayDesc::new(4, 0, 0, 5120, 2880, 2.0);
    for mode in [ScalingMode::FitBlurred, ScalingMode::FillBlurred] {
        let scene = SceneDesc::builder(display.clone(), "/library/drift/scene.json")
            .scaling_mode(mode)
            .build()
            .expect("a valid scene descriptor");
        let template = SceneTemplate::from_scene_desc(&scene);
        assert_eq!(template.scaling_mode, mode);
        let rebuilt = template.for_display(display.clone());
        assert_eq!(rebuilt.scaling_mode, mode);
        assert_eq!(rebuilt, scene);
    }
}

#[test]
fn the_blurred_modes_have_their_own_configuration_names() {
    assert_eq!(ScalingMode::FitBlurred.to_string(), "fit_blurred");
    assert_eq!(ScalingMode::FillBlurred.to_string(), "fill_blurred");
    assert_eq!(ScalingMode::Fit.to_string(), "fit");
    assert_eq!(ScalingMode::Fill.to_string(), "fill");
}
