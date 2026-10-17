use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use super::{
    app::{self, AppConfig},
    wallpaper::{self, WallpaperConfig},
};
use crate::{BridgeError, BridgeErrorKind, paths::BridgePaths};

#[derive(Debug)]
pub struct ConfigLoad {
    pub config: AppConfig,
    pub backup_reported: Vec<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct ConfigStore {
    root: PathBuf,
}

impl ConfigStore {
    #[must_use]
    pub fn default_root() -> PathBuf {
        BridgePaths::new().app_support_root()
    }

    #[must_use]
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The directory every file of this store lives under. Other state that
    /// has to survive a restart (the load journal) is kept beside it.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Parses backup bytes without reading, repairing, or replacing live configuration files.
    pub fn validate_app_config_text(raw: &str) -> Result<(), BridgeError> {
        let config = toml::from_str::<AppConfig>(raw)
            .map_err(|error| config_error(format!("invalid app configuration: {error}")))?;
        check_schema_version(config.schema_version, app::SCHEMA_VERSION, "config")
    }

    pub fn validate_wallpaper_config_text(raw: &str) -> Result<(), BridgeError> {
        let config = serde_json::from_str::<WallpaperConfig>(raw)
            .map_err(|error| config_error(format!("invalid wallpaper configuration: {error}")))?;
        check_schema_version(config.schema_version, wallpaper::SCHEMA_VERSION, "wallpaper config")
    }

    /// # Errors
    ///
    /// Returns an error when the config file is from a newer schema or a
    /// corrupt file cannot be backed up.
    pub fn load(&self) -> Result<ConfigLoad, BridgeError> {
        let path = self.config_path();
        if !path.exists() {
            let config = AppConfig::default();
            return Ok(ConfigLoad {
                config,
                backup_reported: Vec::new(),
            });
        }

        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) => {
                let backup = backup_corrupted(&path)?;
                let config = AppConfig::default();
                log::warn!(
                    "backed up unreadable app config path={} backup={} error={error}",
                    path.display(),
                    backup.display()
                );
                return Ok(ConfigLoad {
                    config,
                    backup_reported: vec![backup],
                });
            }
        };

        match toml::from_str::<AppConfig>(&raw) {
            Ok(mut config) => {
                check_schema_version(config.schema_version, app::SCHEMA_VERSION, "config")?;
                config.migrate_legacy_keys();

                Ok(ConfigLoad {
                    config,
                    backup_reported: Vec::new(),
                })
            }
            Err(error) => {
                let backup = backup_corrupted(&path)?;
                let config = AppConfig::default();
                log::warn!(
                    "backed up corrupted app config path={} backup={} error={error}",
                    path.display(),
                    backup.display()
                );
                Ok(ConfigLoad {
                    config,
                    backup_reported: vec![backup],
                })
            }
        }
    }

    /// # Errors
    ///
    /// Returns an error when the config cannot be serialized or written
    /// atomically.
    pub fn save_app_config(&self, config: &AppConfig) -> Result<(), BridgeError> {
        let bytes = toml::to_string_pretty(config)
            .map_err(|error| config_error(error.to_string()))?
            .into_bytes();
        super::writer::atomic_write(&self.config_path(), &bytes)?;
        Ok(())
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper config cannot be read, parsed, or
    /// backed up.
    pub fn load_wallpaper(&self, id: &str) -> Result<WallpaperConfig, BridgeError> {
        let path = self.wallpaper_path(id);
        if !path.exists() {
            return Ok(WallpaperConfig::new_for(id, "scene"));
        }

        let raw = match fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(error) => {
                let _backup = backup_corrupted(&path)?;
                return Err(config_error(format!(
                    "failed to read wallpaper config {id}: {error}"
                )));
            }
        };
        let config = match serde_json::from_str::<WallpaperConfig>(&raw) {
            Ok(config) => config,
            Err(error) => {
                let _backup = backup_corrupted(&path)?;
                return Err(config_error(format!(
                    "corrupted wallpaper config {id}: {error}"
                )));
            }
        };

        check_schema_version(config.schema_version, wallpaper::SCHEMA_VERSION, "wallpaper config")?;

        Ok(config)
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper config cannot be serialized or
    /// written atomically.
    pub fn save_wallpaper(&self, config: &WallpaperConfig) -> Result<(), BridgeError> {
        let bytes = serde_json::to_string_pretty(config)
            .map_err(|error| config_error(error.to_string()))?
            .into_bytes();
        super::writer::atomic_write(&self.wallpaper_path(&config.workshop_id), &bytes)?;
        Ok(())
    }

    /// # Errors
    ///
    /// This compatibility shim currently does not fail.
    pub fn flush(&self) -> Result<usize, BridgeError> {
        // Temporary compatibility shim: config writes are immediate.
        Ok(0)
    }

    fn config_path(&self) -> PathBuf {
        self.root.join("config.toml")
    }

    fn wallpaper_path(&self, id: &str) -> PathBuf {
        self.root.join("wallpapers").join(format!("{id}.json"))
    }
}

fn check_schema_version(version: u32, supported: u32, name: &str) -> Result<(), BridgeError> {
    if version > supported {
        return Err(config_error(format!(
            "{name} schema version {version} is newer than supported version {supported}"
        )));
    }
    Ok(())
}

fn backup_corrupted(path: &Path) -> Result<PathBuf, BridgeError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let file_name = path
        .file_name()
        .expect("config path has file name")
        .to_string_lossy();
    let backup = path.with_file_name(format!("{file_name}.corrupted-{timestamp}"));
    fs::rename(path, &backup)?;
    Ok(backup)
}

fn config_error(message: impl Into<String>) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Config,
        message: message.into(),
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(error: std::io::Error) -> Self {
        BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ConfigStore;
    use crate::config::{AppConfig, MonitorSettingsCfg, SceneResolutionCfg};

    fn load_config(contents: &str) -> crate::config::AppConfig {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("config.toml"), contents).unwrap();
        ConfigStore::open(root.path().to_path_buf())
            .load()
            .expect("config load")
            .config
    }

    /// Neither plain videos nor scenes have a renderer setting any more, and the scene engine no
    /// longer plays a plain video, so the two experimental switches for it are gone too. A config
    /// an earlier build wrote may still hold the keys it used (`video_backend`, `scene_renderer`,
    /// their one-time markers, and `experimental.native_video_backend`, `content_pacing` and
    /// `shared_video_decode`), whatever their values; it loads, the other settings in it are
    /// kept, and the keys are not written back.
    #[test]
    fn a_config_with_the_old_renderer_keys_loads_and_does_not_write_them_back() {
        for scene_renderer in ["compatibility", "native_metal_preferred", "native_metal_only"] {
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("config.toml");
            std::fs::write(
                &path,
                format!(
                    "video_backend = \"compatibility\"\nnative_video_default_applied = true\n\
                     native_metal_default_applied = true\nscene_renderer = \"{scene_renderer}\"\n\
                     [experimental]\nnative_video_backend = true\ncontent_pacing = true\n\
                     shared_video_decode = true\nscene_video_plane_sampling = true\n"
                ),
            )
            .unwrap();
            let store = ConfigStore::open(root.path().to_path_buf());

            let config = store.load().expect("config load").config;
            assert!(
                config.experimental.scene_video_plane_sampling,
                "the rest of the file is read as before"
            );

            store.save_app_config(&config).expect("config save");
            let written = std::fs::read_to_string(&path).unwrap();
            for key in [
                "video_backend",
                "native_video",
                "scene_renderer",
                "native_metal",
                "content_pacing",
                "shared_video_decode",
            ] {
                assert!(!written.contains(key), "{scene_renderer}: {key} was written back: {written}");
            }
            assert!(written.contains("scene_video_plane_sampling = true"), "{written}");
        }
    }

    /// A config from before the one-time move to Native Metal holds only the old default,
    /// `compatibility`, and no marker. It loads the same way: there is nothing to move to.
    #[test]
    fn a_config_from_before_the_native_default_loads_without_a_marker() {
        let config = load_config("scene_renderer = \"compatibility\"\n[quality]\nrender_scale = 0.75\n");

        assert_eq!(config.quality.render_scale, 0.75, "the neighbouring setting is untouched");
    }

    #[test]
    fn a_new_install_writes_no_renderer_keys() {
        let root = tempfile::tempdir().unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());
        let config = store.load().expect("config load").config;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(root.path().join("config.toml")).unwrap();
        assert!(!written.contains("video_backend"), "{written}");
        assert!(!written.contains("scene_renderer"), "{written}");
        assert!(!written.contains("native_metal_default_applied"), "{written}");
    }

    #[test]
    fn a_config_that_never_heard_of_the_scene_settings_reads_the_shipped_defaults() {
        let config = load_config("[general]\n");

        assert!(
            !config.quality.scene_on_demand_enabled,
            "stopping a scene's tick is opted into; an older config must not arrive already on"
        );
    }

    #[test]
    fn the_scene_settings_survive_a_save_and_reload() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut config = crate::config::AppConfig::default();
        config.quality.scene_on_demand_enabled = true;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("scene_on_demand_enabled = true"), "{written}");
        let reloaded = store.load().expect("config load").config;
        assert!(reloaded.quality.scene_on_demand_enabled);
    }

    /// A config written before the choice existed has no key for it, and the
    /// shipped default applies: a 2D scene is rasterized for the display.
    #[test]
    fn a_config_that_never_heard_of_the_scene_resolution_reads_the_display() {
        let config = load_config("[quality]\nrender_scale = 0.75\n");

        assert_eq!(config.quality.scene_resolution, SceneResolutionCfg::Display);
        assert_eq!(config.quality.render_scale, 0.75, "the neighbouring setting is untouched");
    }

    #[test]
    fn the_scene_resolution_survives_a_save_and_reload_under_its_own_key() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut config = AppConfig::default();
        config.quality.scene_resolution = SceneResolutionCfg::Canvas;

        store.save_app_config(&config).expect("config save");

        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.contains("scene_resolution = \"canvas\""), "{written}");
        let reloaded = store.load().expect("config load").config;
        assert_eq!(
            reloaded.quality.scene_resolution,
            SceneResolutionCfg::Canvas,
            "a return to the canvas is not moved back to the default"
        );
    }

    #[test]
    fn legacy_mirror_target_fps_follows_the_display_unless_it_was_an_explicit_cap() {
        let untouched = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 60\n");
        assert_eq!(untouched.monitor_settings[0].frame_rate, None);
        let missing = load_config("[[monitor_settings]]\nkind = \"primary\"\n");
        assert_eq!(missing.monitor_settings[0].frame_rate, None);

        let capped = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 30\n");
        assert_eq!(capped.monitor_settings[0].frame_rate, Some(30));
        let zero = load_config("[[monitor_settings]]\nkind = \"primary\"\ntarget_fps = 0\n");
        assert_eq!(zero.monitor_settings[0].frame_rate, Some(1));

        let newer_wins = load_config(
            "[[monitor_settings]]\nkind = \"primary\"\nframe_rate = 24\ntarget_fps = 30\n",
        );
        assert_eq!(newer_wins.monitor_settings[0].frame_rate, Some(24));

        let root = tempfile::tempdir().unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut following = AppConfig::default();
        following.monitor_settings.push(MonitorSettingsCfg::default());
        store.save_app_config(&following).expect("config save");
        let written = std::fs::read_to_string(root.path().join("config.toml")).unwrap();
        let tables = monitor_settings_tables(&written);
        assert_eq!(tables.len(), 1, "{written}");
        assert!(tables[0].get("target_fps").is_none(), "{written}");
        assert!(tables[0].get("frame_rate").is_none(), "{written}");

        let mut capped = AppConfig::default();
        capped.monitor_settings.push(MonitorSettingsCfg {
            frame_rate: Some(30),
            ..MonitorSettingsCfg::default()
        });
        store.save_app_config(&capped).expect("config save");
        let written = std::fs::read_to_string(root.path().join("config.toml")).unwrap();
        let tables = monitor_settings_tables(&written);
        assert!(tables[0].get("target_fps").is_none(), "{written}");
        assert_eq!(tables[0].get("frame_rate").and_then(toml::Value::as_integer), Some(30));
        assert_eq!(
            store.load().expect("config load").config.monitor_settings[0].frame_rate,
            Some(30)
        );
    }

    fn monitor_settings_tables(written: &str) -> Vec<toml::Value> {
        let value: toml::Value = toml::from_str(written).unwrap();
        value
            .get("monitor_settings")
            .and_then(toml::Value::as_array)
            .cloned()
            .unwrap_or_default()
    }
}
