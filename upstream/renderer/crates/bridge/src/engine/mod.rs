mod activation;
mod activation_remaining;
mod facade;
mod load_journal;
mod render_settings;
pub(crate) mod revalidate;

pub use activation::{ActivationInputs, RenderBackendSurvey, VideoBackendRouting};
pub use activation_remaining::WallpaperAssignmentExt;
#[cfg(test)]
pub use facade::FakeEngineFacade;
pub(crate) use facade::displays_awaiting_first_frame;
pub use facade::{AudioCaptureDemand, EngineFacade, RealEngineFacade, SceneRuntimeReport};
#[cfg(test)]
pub(crate) use facade::{
    AudioRestartState, OutputWatchGate, RestartAction, apply_audio_capture_demand,
    handle_audio_restart_retry, handle_output_device_change,
};
pub(crate) use load_journal::build_stamp;
pub use load_journal::{LoadJournal, LoadTicket};
