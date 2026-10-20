use super::{
    DisplayDescExt, DisplayIdentityExt, DisplaySelectorExt, DisplaySnapshotExt, MonitorRow,
};
use crate::config::{AppConfig, MonitorCfg, SerializedSelector};
use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry};

pub(super) fn stable_identity_available(identity: &DisplayIdentity) -> bool {
    identity
        .uuid
        .as_deref()
        .map_or(false, |uuid| !uuid.is_empty())
        || (identity.vendor_id.is_some()
            && identity.model_id.is_some()
            && (identity.serial_number.is_some() || identity.unit_number.is_some()))
}

impl DisplaySnapshotExt for DisplaySnapshotEntry {
    fn connected_selector(&self) -> SerializedSelector {
        self.stable_identity_selector()
            .unwrap_or(SerializedSelector::LiveDisplayId {
                display_id: self.desc.display_id,
            })
    }

    fn config_selector(&self, displays: &[DisplaySnapshotEntry]) -> SerializedSelector {
        if displays
            .first()
            .map_or(false, |primary| self.matches_primary(primary))
        {
            SerializedSelector::Primary
        } else {
            self.connected_selector()
        }
    }

    fn stable_identity_selector(&self) -> Option<SerializedSelector> {
        if self.identity.has_stable_identity() {
            Some(SerializedSelector::Identity {
                uuid: self.identity.uuid.clone(),
                vendor_id: self.identity.vendor_id,
                model_id: self.identity.model_id,
                serial_number: self.identity.serial_number,
                unit_number: self.identity.unit_number,
                name: self.identity.name.clone(),
            })
        } else {
            None
        }
    }

    fn matches_primary(&self, primary: &Self) -> bool {
        self.desc.display_id == primary.desc.display_id
            || self.identity.same_physical_identity(&primary.identity)
    }
}

impl DisplayDescExt for DisplayDesc {
    fn same_physical_display(&self, other: &Self) -> bool {
        self.display_id == other.display_id || self.identity.same_physical_identity(&other.identity)
    }
}

impl DisplaySelectorExt for DisplaySelector {
    fn matches_primary(
        &self,
        primary: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> bool {
        match self {
            Self::Primary => true,
            Self::Identity(identity) => identity.same_physical_identity(&primary.identity),
            Self::LiveDisplayId(display_id) => {
                *display_id == primary.desc.display_id
                    || displays
                        .iter()
                        .find(|display| display.desc.display_id == *display_id)
                        .map_or(false, |display| display.matches_primary(primary))
            }
        }
    }

    fn matches_display(&self, display: &DisplaySnapshotEntry) -> bool {
        match self {
            Self::Primary => false,
            Self::Identity(identity) => identity.same_physical_identity(&display.identity),
            Self::LiveDisplayId(display_id) => *display_id == display.desc.display_id,
        }
    }

    fn resolve_display<'a>(
        &self,
        displays: &'a [DisplaySnapshotEntry],
    ) -> Option<&'a DisplaySnapshotEntry> {
        match self {
            Self::Primary => displays.first(),
            _ => displays
                .iter()
                .find(|display| self.matches_display(display)),
        }
    }
}

impl SerializedSelector {
    pub fn mirror_target_id(
        &self,
        entry: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> Option<String> {
        let selected = match self {
            Self::Primary => displays
                .first()
                .filter(|display| display.desc.display_id != entry.desc.display_id),
            _ => {
                let selector = self.to_selector();
                displays.iter().find(|display| {
                    display.desc.display_id != entry.desc.display_id
                        && selector.matches_display(display)
                })
            }
        }?;
        Some(selected.config_selector(displays).id())
    }
}

impl AppConfig {
    pub fn normalized(&self, displays: &[DisplaySnapshotEntry]) -> Self {
        let mut synchronized = self.clone();
        synchronized.sync_known_monitors(displays);
        synchronized
    }

    pub fn monitor_rows(&self, displays: &[DisplaySnapshotEntry]) -> Vec<MonitorRow> {
        let mut rows: Vec<MonitorRow> = Vec::new();
        for (index, display) in displays.iter().enumerate() {
            if index != 0 && display.matches_primary(&displays[0]) {
                continue;
            }
            let selector = if index == 0 {
                SerializedSelector::Primary
            } else {
                display.connected_selector()
            };
            let config = self
                .monitors
                .iter()
                .find(|config| config.selector == selector)
                .cloned()
                .unwrap_or_else(|| {
                    MonitorCfg::for_connected_display(
                        selector.clone(),
                        display,
                        self.primary_wallpaper(),
                    )
                });
            rows.push(MonitorRow {
                selector,
                config,
                connected: true,
                display_index: Some(index),
            });
        }
        for config in &self.monitors {
            if rows.iter().any(|row| row.selector == config.selector) {
                continue;
            }
            if displays.first().map_or(false, |primary| {
                config
                    .selector
                    .to_selector()
                    .matches_primary(primary, displays)
            }) {
                continue;
            }
            rows.push(MonitorRow {
                selector: config.selector.clone(),
                config: config.clone(),
                connected: false,
                display_index: None,
            });
        }
        rows
    }

    pub fn sync_known_monitors(&mut self, displays: &[DisplaySnapshotEntry]) -> bool {
        let previous_monitors = self.monitors.clone();
        let previous_settings = self.monitor_settings.clone();
        self.merge_display_aliases(displays);

        let mut protected_primary = match self
            .monitors
            .iter()
            .position(|config| config.selector == SerializedSelector::Primary)
        {
            Some(index) => self.monitors.remove(index),
            None => MonitorCfg::default(),
        };
        protected_primary.enabled = true;
        if protected_primary.mode != "independent" {
            protected_primary.mode = "independent".into();
        }
        protected_primary.mirror_target = None;

        if let Some(primary) = displays.first() {
            self.monitors.retain_mut(|config| {
                let primary_live_alias = match &config.selector {
                    SerializedSelector::LiveDisplayId { display_id } => {
                        DisplaySelector::LiveDisplayId(*display_id)
                            .matches_primary(primary, displays)
                    }
                    _ => false,
                };
                if primary_live_alias && protected_primary.wallpaper.is_none() {
                    protected_primary.wallpaper = config.wallpaper.take();
                }
                !primary_live_alias
            });
            if protected_primary.wallpaper.is_none() {
                if let Some(selector) = primary.stable_identity_selector() {
                    if let Some(config) = self
                        .monitors
                        .iter()
                        .find(|config| config.selector == selector)
                    {
                        protected_primary.wallpaper = config.wallpaper.clone();
                    }
                }
            }
        }
        self.monitors.insert(0, protected_primary);

        for (index, display) in displays.iter().enumerate() {
            if index == 0 || display.matches_primary(&displays[0]) {
                continue;
            }
            let selector = display.connected_selector();
            if self
                .monitors
                .iter()
                .any(|config| config.selector == selector)
            {
                continue;
            }
            let config =
                MonitorCfg::for_connected_display(selector, display, self.primary_wallpaper());
            self.monitors.push(config);
        }
        previous_monitors != self.monitors || previous_settings != self.monitor_settings
    }

    pub fn ensure_monitor(&mut self, selector: SerializedSelector) -> &mut MonitorCfg {
        let index = match self
            .monitors
            .iter()
            .position(|config| config.selector == selector)
        {
            Some(index) => index,
            None => {
                self.monitors.push(MonitorCfg {
                    selector,
                    ..MonitorCfg::default()
                });
                self.monitors.len() - 1
            }
        };
        &mut self.monitors[index]
    }
}
