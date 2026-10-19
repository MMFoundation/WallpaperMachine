// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
use std::collections::HashSet;

#[cfg(test)]
use crate::{DisplayConfig, project::SceneTemplate};
use crate::{
    DisplayDesc, DisplayIdentity, DisplaySelector, EngineError, WallpaperAssignment,
    WallpaperEngineConfig,
    project::{SceneDesc, SceneTemplate as Template},
};

/// The name of a display slot in the model.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum DisplayKey {
    Primary,
    Identity(DisplayIdentity),
    LiveDisplayId(u32),
}

/// What the engine must do with the scene of one slot after a model change.
#[derive(Clone, Debug, PartialEq)]
pub enum DisplayAction {
    Open(DisplayKey),
    Close(DisplayKey),
    Rebuild(DisplayKey),
}

/// One display slot: its key, live display, assignment and flags.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayRecord {
    pub key: DisplayKey,
    pub live_display: Option<DisplayDesc>,
    pub assignment: Option<WallpaperAssignment>,
    pub window_active: bool,
    pub runtime_open: bool,
    pub primary_inheritance_consumed: bool,
}

impl DisplayRecord {
    /// Whether a scene should exist for this slot: its window is active or
    /// a scene is already open, a display is connected and something is
    /// assigned (a mirror counts; the engine resolves mirrors first).
    pub fn should_have_runtime(&self) -> bool {
        (self.window_active || self.runtime_open)
            && self.live_display.is_some()
            && self.assignment.is_some()
    }

    pub fn scene_desc(&self) -> Result<Option<SceneDesc>, EngineError> {
        let Some(display) = &self.live_display else {
            return Ok(None);
        };
        match &self.assignment {
            None => Ok(None),
            Some(WallpaperAssignment::Direct(template)) => {
                template.validate()?;
                Ok(Some(template.for_display(display.clone())))
            }
            Some(WallpaperAssignment::Mirror(_)) => Err(EngineError::Platform(
                "mirror assignments must be resolved before runtime creation".to_string(),
            )),
        }
    }

    /// A slot that came into being without any configuration: inactive,
    /// disconnected and blank.
    fn blank(key: DisplayKey) -> Self {
        Self {
            key,
            live_display: None,
            assignment: None,
            window_active: false,
            runtime_open: false,
            primary_inheritance_consumed: false,
        }
    }

    /// Whether the slot's wallpaper claims its display for a scene to run
    /// on it right now (before mirrors are resolved).
    fn is_claimed(&self) -> bool {
        self.window_active || self.runtime_open
    }
}

/// A display transition worth a debug line.
#[derive(Clone, Debug, PartialEq)]
pub enum DisplayDebugEvent {
    Connected {
        key: DisplayKey,
        display: DisplayDesc,
    },
    Disconnected {
        key: DisplayKey,
        display: DisplayDesc,
    },
    Changed {
        key: DisplayKey,
        before: DisplayDesc,
        after: DisplayDesc,
    },
}

/// All display slots, primary first, then in order of creation.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DisplayStateModel {
    pub records: Vec<DisplayRecord>,
}

impl DisplayKey {
    pub fn key_label(&self) -> String {
        match self {
            Self::Primary => "the primary slot".to_owned(),
            Self::Identity(identity) => format!("slot for {}", identity.identity_label()),
            Self::LiveDisplayId(id) => format!("slot for live display #{id}"),
        }
    }

    pub fn from_selector(selector: &DisplaySelector) -> Result<Self, EngineError> {
        match selector {
            DisplaySelector::Primary => Ok(Self::Primary),
            DisplaySelector::Identity(identity) if identity.is_empty() => {
                Err(EngineError::InvalidInput(
                    "display identity selector must not be empty".to_string(),
                ))
            }
            DisplaySelector::Identity(identity) => Ok(Self::Identity(identity.clone())),
            DisplaySelector::LiveDisplayId(0) => Err(EngineError::InvalidInput(
                "display_id must be non-zero".to_string(),
            )),
            DisplaySelector::LiveDisplayId(id) => Ok(Self::LiveDisplayId(*id)),
        }
    }
}

fn mirror_cycle_error() -> EngineError {
    EngineError::InvalidInput("wallpaper mirror cycle detected".to_string())
}

impl DisplayStateModel {
    pub fn from_config(config: WallpaperEngineConfig) -> Result<Self, EngineError> {
        // Read every entry first, so a mirror loop spanning two entries is
        // judged on the complete configuration.
        let entries = config
            .displays
            .into_iter()
            .map(|entry| {
                if let Some(WallpaperAssignment::Direct(template)) = &entry.wallpaper {
                    template.validate()?;
                }
                let key = DisplayKey::from_selector(&entry.selector)?;
                Ok((key, entry.window_active, entry.wallpaper))
            })
            .collect::<Result<Vec<_>, EngineError>>()?;

        let mut model = Self {
            records: vec![DisplayRecord {
                window_active: true,
                ..DisplayRecord::blank(DisplayKey::Primary)
            }],
        };
        for (key, window_active, assignment) in entries {
            let slot = model.slot_or_insert(key);
            slot.window_active = window_active;
            slot.assignment = assignment;
        }
        model.check_mirror_cycles()?;
        Ok(model)
    }

    pub fn set_assignment(
        &mut self,
        selector: &DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> Result<(), EngineError> {
        if let WallpaperAssignment::Direct(template) = &assignment {
            template.validate()?;
        }
        let key = DisplayKey::from_selector(selector)?;
        let slots_before = self.records.len();
        let index = self.index_or_insert(key);
        let replaced = self.records[index].assignment.replace(assignment);
        if let Err(error) = self.check_mirror_cycles() {
            // Undo: a slot made for this call is the last one.
            self.records[index].assignment = replaced;
            self.records.truncate(slots_before);
            return Err(error);
        }
        Ok(())
    }

    pub fn refresh_connected(
        &mut self,
        primary: DisplayDesc,
        displays: Vec<DisplayDesc>,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        self.refresh_connected_keeping(primary, displays, &[])
    }

    /// Like [`Self::refresh_connected`], for a report in which some displays
    /// have no pixel size yet (`transitional`, absent from `displays`).
    ///
    /// A transitional display that already has a descriptor keeps it, so its
    /// runtime is neither closed nor rebuilt while the display settles. One
    /// that has none gets no live descriptor, so nothing opens on it.
    pub fn refresh_connected_keeping(
        &mut self,
        primary: DisplayDesc,
        displays: Vec<DisplayDesc>,
        transitional: &[DisplayDesc],
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let target = self.model_after_report(&primary, displays, transitional)?;
        let plan = target.scene_plan()?;
        target.log_debug_transition(self);
        *self = target;
        Ok(plan)
    }

    pub fn set_window_active(
        &mut self,
        selector: &DisplaySelector,
        active: bool,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let key = DisplayKey::from_selector(selector)?;
        let mut next = self.clone();
        next.slot_or_insert(key).window_active = active;
        let actions = next.scene_plan()?;
        *self = next;
        Ok(actions)
    }

    pub fn destroy_window(
        &mut self,
        selector: &DisplaySelector,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let key = DisplayKey::from_selector(selector)?;
        let slot = self.slot_or_insert(key.clone());
        slot.window_active = false;
        let had_scene = std::mem::take(&mut slot.runtime_open);
        Ok(had_scene
            .then_some(DisplayAction::Close(key))
            .into_iter()
            .collect())
    }

    pub fn resolved_assignment(
        &self,
        key: &DisplayKey,
    ) -> Result<Option<WallpaperAssignment>, EngineError> {
        let Some(mut record) = self.slot(key) else {
            return Ok(None);
        };
        let mut visited = vec![&record.key];
        loop {
            match &record.assignment {
                None => return Ok(None),
                Some(direct @ WallpaperAssignment::Direct(_)) => return Ok(Some(direct.clone())),
                Some(WallpaperAssignment::Mirror(source)) => {
                    let source_key = DisplayKey::from_selector(source)?;
                    let Some(source_record) = self.slot(&source_key) else {
                        return Ok(None);
                    };
                    if visited.contains(&&source_record.key) {
                        return Err(mirror_cycle_error());
                    }
                    visited.push(&source_record.key);
                    record = source_record;
                }
            }
        }
    }

    pub fn apply_reconcile(&mut self, scenes: &[SceneDesc]) -> Result<(), EngineError> {
        // Every placement is decided against the model as it is now.
        let keys = scenes
            .iter()
            .map(|scene| self.reconcile_key(scene))
            .collect::<Result<Vec<_>, _>>()?;
        let mut next = self.clone();
        for record in &mut next.records {
            if record.live_display.is_some() && !keys.contains(&record.key) {
                record.window_active = false;
                record.runtime_open = false;
            }
        }
        for (scene, key) in scenes.iter().zip(keys) {
            let record = next.slot_or_insert(key);
            record.live_display = Some(scene.display.clone());
            record.window_active = true;
            record.assignment = Some(WallpaperAssignment::Direct(Template::from_scene_desc(
                scene,
            )));
        }
        *self = next;
        Ok(())
    }

    pub fn reconcile_key(&self, scene: &SceneDesc) -> Result<DisplayKey, EngineError> {
        let display = &scene.display;
        let shows_display = |record: &&DisplayRecord| {
            record
                .live_display
                .as_ref()
                .is_some_and(|live| live.display_id == display.display_id)
        };
        let primary_shows = self
            .slot(&DisplayKey::Primary)
            .iter()
            .any(|record| shows_display(record));
        if primary_shows {
            return Ok(DisplayKey::Primary);
        }
        if let Some(record) = self.records.iter().find(shows_display) {
            return Ok(record.key.clone());
        }
        if !display.identity.is_empty()
            && let Some(key) = self.best_identity_slot(&display.identity, display.display_id)?
        {
            return Ok(key);
        }
        Ok(DisplayKey::LiveDisplayId(display.display_id))
    }

    pub fn has_live_id(&self, display_id: u32) -> bool {
        self.records.iter().any(|record| {
            record
                .live_display
                .as_ref()
                .is_some_and(|live| live.display_id == display_id)
        })
    }

    pub fn debug_events_since(&self, before: &DisplayStateModel) -> Vec<DisplayDebugEvent> {
        let mut events = Vec::new();
        for record in &self.records {
            if let Some(display) = &record.live_display
                && !before.has_live_id(display.display_id)
            {
                events.push(DisplayDebugEvent::Connected {
                    key: record.key.clone(),
                    display: display.clone(),
                });
            }
        }
        for record in &before.records {
            if let Some(display) = &record.live_display
                && !self.has_live_id(display.display_id)
            {
                events.push(DisplayDebugEvent::Disconnected {
                    key: record.key.clone(),
                    display: display.clone(),
                });
            }
        }
        for record in &self.records {
            let (Some(after), Some(old)) = (
                &record.live_display,
                before
                    .slot(&record.key)
                    .and_then(|old| old.live_display.as_ref()),
            ) else {
                continue;
            };
            if !old.has_same_geometry(after) {
                events.push(DisplayDebugEvent::Changed {
                    key: record.key.clone(),
                    before: old.clone(),
                    after: after.clone(),
                });
            }
        }
        events
    }

    pub fn log_debug_transition(&self, before: &DisplayStateModel) {
        for event in self.debug_events_since(before) {
            match event {
                DisplayDebugEvent::Connected { key, display } => log::debug!(
                    "[wallpaper-core display] connected {} on {}",
                    display.desc_label(),
                    key.key_label()
                ),
                DisplayDebugEvent::Disconnected { key, display } => log::debug!(
                    "[wallpaper-core display] disconnected {} from {}",
                    display.desc_label(),
                    key.key_label()
                ),
                DisplayDebugEvent::Changed { key, before, after } => log::debug!(
                    "[wallpaper-core display] changed {}: {} -> {}",
                    key.key_label(),
                    before.desc_label(),
                    after.desc_label()
                ),
            }
        }
    }

    // ---- private helpers -------------------------------------------------

    fn slot(&self, key: &DisplayKey) -> Option<&DisplayRecord> {
        self.records.iter().find(|record| &record.key == key)
    }

    /// Position of the slot named `key`; a blank inactive slot is appended
    /// first when there is none.
    fn index_or_insert(&mut self, key: DisplayKey) -> usize {
        self.records
            .iter()
            .position(|record| record.key == key)
            .unwrap_or_else(|| {
                self.records.push(DisplayRecord::blank(key));
                self.records.len() - 1
            })
    }

    fn slot_or_insert(&mut self, key: DisplayKey) -> &mut DisplayRecord {
        let index = self.index_or_insert(key);
        &mut self.records[index]
    }

    #[cfg(test)]
    fn record(&self, key: &DisplayKey) -> Option<&DisplayRecord> {
        self.slot(key)
    }

    #[cfg(test)]
    fn ensure_record(&mut self, key: DisplayKey) -> &mut DisplayRecord {
        self.slot_or_insert(key)
    }

    #[cfg(test)]
    fn plan_actions(&self) -> Result<Vec<DisplayAction>, EngineError> {
        self.scene_plan()
    }

    /// The model a display report leads to, computed without touching
    /// `self`: every key decision reads the slots as they stand now.
    fn model_after_report(
        &self,
        primary: &DisplayDesc,
        displays: Vec<DisplayDesc>,
        transitional: &[DisplayDesc],
    ) -> Result<Self, EngineError> {
        let landings = self.landings(primary, displays)?;
        let primary_assignment = self
            .slot(&DisplayKey::Primary)
            .and_then(|record| record.assignment.clone());

        // Existing slots keep their place; slots born in this report follow
        // in the order their displays were listed.
        let mut keys: Vec<&DisplayKey> = self.records.iter().map(|record| &record.key).collect();
        keys.extend(
            landings
                .iter()
                .map(|(key, _)| key)
                .filter(|key| self.slot(key).is_none()),
        );

        let records = keys
            .into_iter()
            .map(|key| {
                let before = self.slot(key);
                let landed = landings
                    .iter()
                    .find(|(landing_key, _)| landing_key == key)
                    .map(|(_, display)| display);
                let mut record = before
                    .cloned()
                    .unwrap_or_else(|| DisplayRecord::blank(key.clone()));
                // A display that still reports no pixels keeps the slot it
                // ran on.
                record.live_display = landed.cloned().or_else(|| {
                    before
                        .and_then(|old| old.live_display.as_ref())
                        .filter(|previous| {
                            transitional
                                .iter()
                                .any(|display| previous.is_same_physical_display_as(display))
                        })
                        .cloned()
                });
                if let Some(display) = landed {
                    let eligible = !record.primary_inheritance_consumed
                        && record.assignment.is_none()
                        && display.display_id != primary.display_id;
                    if eligible {
                        record.assignment.clone_from(&primary_assignment);
                        record.primary_inheritance_consumed = true;
                    }
                }
                record
            })
            .collect();

        let mut candidate = Self { records };
        candidate.check_mirror_cycles()?;
        candidate.carry_scene_marks_from(self)?;
        Ok(candidate)
    }

    /// The slot every connected display of a report lands on, primary first.
    fn landings(
        &self,
        primary: &DisplayDesc,
        displays: Vec<DisplayDesc>,
    ) -> Result<Vec<(DisplayKey, DisplayDesc)>, EngineError> {
        let mut landings = vec![(self.slot_for_primary(primary), primary.clone())];
        for display in displays {
            // A mirrored or duplicated listing of the primary is not a
            // second display.
            if display.display_id == primary.display_id
                || primary.identity.match_score(&display.identity).is_some()
            {
                continue;
            }
            landings.push((self.slot_for_display(&display)?, display));
        }
        let mut seen = HashSet::new();
        if let Some((key, _)) = landings.iter().find(|(key, _)| !seen.insert(key)) {
            return Err(EngineError::InvalidInput(format!(
                "multiple connected displays matched the display slot {}",
                key.key_label()
            )));
        }
        Ok(landings)
    }

    /// The identity slot whose key names `identity` best (its own identity
    /// is the matcher), `None` without any match; a tie at the top is an
    /// error.
    fn best_identity_slot(
        &self,
        identity: &DisplayIdentity,
        display_id: u32,
    ) -> Result<Option<DisplayKey>, EngineError> {
        let mut best: Option<(u8, &DisplayKey)> = None;
        let mut tied = false;
        for record in &self.records {
            let DisplayKey::Identity(configured) = &record.key else {
                continue;
            };
            let Some(score) = configured.match_score(identity) else {
                continue;
            };
            match best {
                Some((top, _)) if score < top => {}
                Some((top, _)) if score == top => tied = true,
                _ => {
                    best = Some((score, &record.key));
                    tied = false;
                }
            }
        }
        if tied {
            return Err(EngineError::InvalidInput(format!(
                "ambiguous display identity match for display {display_id}"
            )));
        }
        Ok(best.map(|(_, key)| key.clone()))
    }

    /// The slot the primary display lands on.
    fn slot_for_primary(&self, primary: &DisplayDesc) -> DisplayKey {
        if self.slot(&DisplayKey::Primary).is_some_and(DisplayRecord::is_claimed) {
            return DisplayKey::Primary;
        }
        let live_id = DisplayKey::LiveDisplayId(primary.display_id);
        if self.slot(&live_id).is_some_and(DisplayRecord::is_claimed) {
            return live_id;
        }
        DisplayKey::Primary
    }

    /// The slot a non-primary display lands on.
    fn slot_for_display(&self, display: &DisplayDesc) -> Result<DisplayKey, EngineError> {
        let live_id = DisplayKey::LiveDisplayId(display.display_id);
        if self.slot(&live_id).is_some_and(DisplayRecord::is_claimed) {
            return Ok(live_id);
        }
        if !display.identity.is_empty()
            && let Some(key) = self.best_identity_slot(&display.identity, display.display_id)?
        {
            return Ok(key);
        }
        if self
            .slot(&live_id)
            .is_some_and(|record| record.assignment.is_some())
        {
            return Ok(live_id);
        }
        Ok(if display.identity.is_empty() {
            live_id
        } else {
            DisplayKey::Identity(display.identity.clone())
        })
    }

    /// Fails when any chain of mirrors loops back on itself.
    fn check_mirror_cycles(&self) -> Result<(), EngineError> {
        for start in &self.records {
            let mut visited = vec![&start.key];
            let mut current = start;
            while let Some(WallpaperAssignment::Mirror(source)) = &current.assignment {
                // A source nobody can name ends the chain; resolving it
                // reports the problem.
                let Ok(source_key) = DisplayKey::from_selector(source) else {
                    break;
                };
                let Some(next) = self.slot(&source_key) else {
                    break;
                };
                if visited.contains(&&next.key) {
                    return Err(mirror_cycle_error());
                }
                visited.push(&next.key);
                current = next;
            }
        }
        Ok(())
    }

    /// Whether a scene should run on the slot: it is claimed, connected and
    /// its assignment ends in a direct template.
    fn wants_scene(&self, record: &DisplayRecord) -> Result<bool, EngineError> {
        if !record.is_claimed() || record.live_display.is_none() {
            return Ok(false);
        }
        let resolved = self.resolved_assignment(&record.key)?;
        Ok(matches!(resolved, Some(WallpaperAssignment::Direct(_))))
    }

    /// Lets each open scene of `earlier` follow its physical display to the
    /// slot that names it in `self`, the freshly refreshed model. A slot
    /// that does not want a scene ends up with no mark.
    fn carry_scene_marks_from(&mut self, earlier: &Self) -> Result<(), EngineError> {
        let mut used = vec![false; earlier.records.len()];
        let mut marks = Vec::with_capacity(self.records.len());
        for record in &self.records {
            if !self.wants_scene(record)? {
                marks.push(false);
                continue;
            }
            let same_display = |index: usize, old: &DisplayRecord| {
                !used[index]
                    && old.runtime_open
                    && matches!(
                        (&old.live_display, &record.live_display),
                        (Some(before), Some(now)) if before.is_same_physical_display_as(now)
                    )
            };
            let donor = earlier
                .records
                .iter()
                .enumerate()
                .find(|&(index, old)| same_display(index, old))
                .or_else(|| {
                    earlier
                        .records
                        .iter()
                        .enumerate()
                        .find(|&(index, old)| !used[index] && old.key == record.key)
                });
            marks.push(donor.is_some_and(|(index, old)| {
                used[index] = true;
                old.runtime_open
            }));
        }
        for (record, mark) in self.records.iter_mut().zip(marks) {
            record.runtime_open = mark;
        }
        Ok(())
    }

    /// What each slot's scene must do, in slot order.
    fn scene_plan(&self) -> Result<Vec<DisplayAction>, EngineError> {
        let mut plan = Vec::new();
        for record in &self.records {
            let key = record.key.clone();
            plan.extend(match (self.wants_scene(record)?, record.runtime_open) {
                (true, false) => Some(DisplayAction::Open(key)),
                (true, true) => Some(DisplayAction::Rebuild(key)),
                (false, true) => Some(DisplayAction::Close(key)),
                (false, false) => None,
            });
        }
        Ok(plan)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(id: u32, identity: DisplayIdentity) -> DisplayDesc {
        DisplayDesc::with_identity(id, identity, 0, 0, 1920, 1080, 1.0)
    }

    fn scaled_display(
        id: u32,
        identity: DisplayIdentity,
        width: u32,
        height: u32,
        scale_factor: f64,
    ) -> DisplayDesc {
        DisplayDesc::with_identity(id, identity, 0, 0, width, height, scale_factor)
    }

    fn identity(label: &str) -> DisplayIdentity {
        DisplayIdentity {
            uuid: Some(label.to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(u32::from(label.bytes().next().unwrap_or_default())),
            unit_number: Some(1),
            name: None,
        }
    }

    fn vendor_model_unit(vendor_id: u32, model_id: u32, unit_number: u32) -> DisplayIdentity {
        DisplayIdentity {
            uuid: None,
            vendor_id: Some(vendor_id),
            model_id: Some(model_id),
            serial_number: None,
            unit_number: Some(unit_number),
            name: None,
        }
    }

    fn template(path: &str) -> SceneTemplate {
        SceneTemplate::builder(path)
            .build()
            .expect("template should build")
    }

    #[test]
    fn default_config_creates_active_blank_primary_record() {
        let model = DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();

        assert_eq!(model.records.len(), 1);
        assert_eq!(model.records[0].key, DisplayKey::Primary);
        assert!(model.records[0].window_active);
        assert!(model.records[0].assignment.is_none());
        assert!(!model.records[0].runtime_open);
    }

    #[test]
    fn future_display_config_is_stored_without_live_display() {
        let external = identity("external");
        let model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/project.json"))),
            }],
        })
        .unwrap();

        assert!(model.records.iter().any(|record| {
            record.key == DisplayKey::Identity(external.clone())
                && record.window_active
                && record.live_display.is_none()
                && record.assignment.is_some()
        }));
    }

    #[test]
    fn connecting_secondary_inherits_primary_assignment_once_but_stays_inactive() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();
        model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Direct(template("/tmp/primary.json")),
            )
            .unwrap();

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();

        let secondary = model
            .records
            .iter()
            .find(|record| record.key == DisplayKey::Identity(external.clone()))
            .expect("secondary record should exist");
        assert_eq!(
            secondary.assignment,
            Some(WallpaperAssignment::Direct(template("/tmp/primary.json")))
        );
        assert!(!secondary.window_active);

        model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Direct(template("/tmp/new-primary.json")),
            )
            .unwrap();
        let secondary = model
            .records
            .iter()
            .find(|record| matches!(record.key, DisplayKey::Identity(_)))
            .expect("secondary record should remain");
        assert_eq!(
            secondary.assignment,
            Some(WallpaperAssignment::Direct(template("/tmp/primary.json")))
        );
    }

    #[test]
    fn refresh_preserves_explicit_live_display_id_record() {
        let external = identity("external");
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: None,
                    assignment: None,
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::LiveDisplayId(2),
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/live.json"))),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();

        let live_record = model
            .record(&DisplayKey::LiveDisplayId(2))
            .expect("legacy live-id record should remain");
        assert_eq!(live_record.live_display, Some(display(2, external)));
        assert!(
            !model
                .records
                .iter()
                .any(|record| matches!(record.key, DisplayKey::Identity(_)))
        );
    }

    #[test]
    fn refresh_skips_primary_duplicate_with_different_live_id() {
        let primary = identity("primary");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();

        model
            .refresh_connected(
                display(1, primary.clone()),
                vec![display(1, primary.clone()), display(99, primary.clone())],
            )
            .unwrap();

        assert_eq!(model.records.len(), 1);
        let primary_record = model
            .record(&DisplayKey::Primary)
            .expect("primary record should remain");
        assert_eq!(
            primary_record.live_display,
            Some(display(1, primary.clone()))
        );
        assert!(
            !model
                .records
                .iter()
                .any(|record| record.key == DisplayKey::Identity(primary.clone())
                    || record.key == DisplayKey::LiveDisplayId(99))
        );
    }

    #[test]
    fn reconcile_scene_for_connected_identity_display_uses_identity_record() {
        let primary = identity("primary");
        let external = identity("external");
        let external_display = display(2, external.clone());
        let scene = SceneDesc::new(
            external_display.clone(),
            "/tmp/requested.json",
            "/tmp/assets",
            60,
            false,
        );
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(display(1, primary)),
                    assignment: None,
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(external.clone()),
                    live_display: Some(external_display.clone()),
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/old.json"))),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        model.apply_reconcile(&[scene]).unwrap();

        let record = model
            .record(&DisplayKey::Identity(external))
            .expect("identity record should remain");
        assert!(record.window_active);
        assert_eq!(record.live_display, Some(external_display));
        assert!(matches!(
            record.assignment,
            Some(WallpaperAssignment::Direct(ref template))
                if template.scene_path == "/tmp/requested.json"
        ));
        assert!(
            !model
                .records
                .iter()
                .any(|record| record.key == DisplayKey::LiveDisplayId(2))
        );
    }

    #[test]
    fn display_debug_events_report_connected_and_disconnected_displays() {
        let primary = identity("primary");
        let external = identity("external");
        let before = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(display(1, primary.clone())),
                    assignment: None,
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(external.clone()),
                    live_display: None,
                    assignment: None,
                    window_active: false,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };
        let after_connect = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(display(1, primary.clone())),
                    assignment: None,
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(external.clone()),
                    live_display: Some(display(2, external.clone())),
                    assignment: None,
                    window_active: false,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        assert_eq!(
            after_connect.debug_events_since(&before),
            vec![DisplayDebugEvent::Connected {
                key: DisplayKey::Identity(external.clone()),
                display: display(2, external.clone()),
            }]
        );

        assert_eq!(
            before.debug_events_since(&after_connect),
            vec![DisplayDebugEvent::Disconnected {
                key: DisplayKey::Identity(external.clone()),
                display: display(2, external),
            }]
        );
    }

    #[test]
    fn display_debug_events_report_logical_resolution_and_scale_changes() {
        let primary = identity("primary");
        let before = DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(scaled_display(1, primary.clone(), 3840, 2160, 2.0)),
                assignment: None,
                window_active: true,
                runtime_open: true,
                primary_inheritance_consumed: false,
            }],
        };
        let after = DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(scaled_display(1, primary.clone(), 3840, 2160, 1.5)),
                assignment: None,
                window_active: true,
                runtime_open: true,
                primary_inheritance_consumed: false,
            }],
        };

        assert_eq!(
            after.debug_events_since(&before),
            vec![DisplayDebugEvent::Changed {
                key: DisplayKey::Primary,
                before: scaled_display(1, primary.clone(), 3840, 2160, 2.0),
                after: scaled_display(1, primary, 3840, 2160, 1.5),
            }]
        );
    }

    #[test]
    fn display_debug_events_report_primary_replacement_as_descriptor_change() {
        let before = DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(scaled_display(1, identity("old"), 3420, 2214, 2.0)),
                assignment: None,
                window_active: true,
                runtime_open: true,
                primary_inheritance_consumed: false,
            }],
        };
        let after = DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(scaled_display(2, identity("new"), 1920, 1080, 1.0)),
                assignment: None,
                window_active: true,
                runtime_open: true,
                primary_inheritance_consumed: false,
            }],
        };

        assert_eq!(
            after.debug_events_since(&before),
            vec![
                DisplayDebugEvent::Connected {
                    key: DisplayKey::Primary,
                    display: scaled_display(2, identity("new"), 1920, 1080, 1.0),
                },
                DisplayDebugEvent::Disconnected {
                    key: DisplayKey::Primary,
                    display: scaled_display(1, identity("old"), 3420, 2214, 2.0),
                },
                DisplayDebugEvent::Changed {
                    key: DisplayKey::Primary,
                    before: scaled_display(1, identity("old"), 3420, 2214, 2.0),
                    after: scaled_display(2, identity("new"), 1920, 1080, 1.0),
                },
            ]
        );
    }

    #[test]
    fn partial_identity_config_matches_full_live_identity() {
        let partial = DisplayIdentity {
            uuid: Some("external".to_string()),
            ..DisplayIdentity::default()
        };
        let full = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(partial.clone()),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/external.json"))),
            }],
        })
        .unwrap();

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary")), display(2, full.clone())],
            )
            .unwrap();

        let matched = model
            .record(&DisplayKey::Identity(partial))
            .expect("partial identity record should remain");
        assert_eq!(matched.live_display, Some(display(2, full)));
        assert!(
            !model
                .records
                .iter()
                .any(|record| record.key == DisplayKey::Identity(identity("external")))
        );
    }

    #[test]
    fn ambiguous_identity_match_errors_and_preserves_model() {
        let mut first = vendor_model_unit(7, 8, 9);
        first.name = Some("first".to_string());
        let mut second = vendor_model_unit(7, 8, 9);
        second.name = Some("second".to_string());
        let live = DisplayIdentity {
            uuid: Some("live".to_string()),
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(10),
            unit_number: Some(9),
            name: Some("connected".to_string()),
        };
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![
                DisplayConfig {
                    selector: DisplaySelector::Identity(first),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/first.json"))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(second),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/second.json"))),
                },
            ],
        })
        .unwrap();
        let before = model.clone();

        let error = model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary")), display(2, live)],
            )
            .expect_err("ambiguous identity match should fail");

        match error {
            EngineError::InvalidInput(message) => assert!(message.contains("ambiguous")),
            other => panic!("expected invalid input, got {other:?}"),
        }
        assert_eq!(model, before);
    }

    #[test]
    fn unique_higher_score_identity_match_wins_over_lower_score_ties() {
        let mut lower_first = vendor_model_unit(7, 8, 9);
        lower_first.name = Some("lower-first".to_string());
        let mut lower_second = vendor_model_unit(7, 8, 9);
        lower_second.name = Some("lower-second".to_string());
        let higher = DisplayIdentity {
            uuid: None,
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(10),
            unit_number: None,
            name: Some("higher".to_string()),
        };
        let live = DisplayIdentity {
            uuid: Some("live".to_string()),
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(10),
            unit_number: Some(9),
            name: Some("connected".to_string()),
        };
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![
                DisplayConfig {
                    selector: DisplaySelector::Identity(lower_first),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/lower-a.json"))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(lower_second),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/lower-b.json"))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(higher.clone()),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/higher.json"))),
                },
            ],
        })
        .unwrap();

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary")), display(2, live.clone())],
            )
            .unwrap();

        let matched = model
            .record(&DisplayKey::Identity(higher))
            .expect("higher score identity should remain");
        assert_eq!(matched.live_display, Some(display(2, live)));
    }

    #[test]
    fn primary_refresh_prefers_primary_record_over_stale_live_id() {
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::LiveDisplayId(1),
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/stale.json"))),
                    window_active: false,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary"))],
            )
            .unwrap();

        assert_eq!(
            model.record(&DisplayKey::Primary).unwrap().live_display,
            Some(display(1, identity("primary")))
        );
        assert_eq!(
            model
                .record(&DisplayKey::LiveDisplayId(1))
                .unwrap()
                .live_display,
            None
        );
    }

    #[test]
    fn active_live_id_primary_wins_over_inactive_primary_assignment() {
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
                    window_active: false,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::LiveDisplayId(1),
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/live.json"))),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary"))],
            )
            .unwrap();

        assert_eq!(
            model.record(&DisplayKey::Primary).unwrap().live_display,
            None
        );
        assert_eq!(
            model
                .record(&DisplayKey::LiveDisplayId(1))
                .unwrap()
                .live_display,
            Some(display(1, identity("primary")))
        );
    }

    #[test]
    fn inactive_live_id_assignment_does_not_mask_matching_identity() {
        let external = identity("external");
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: None,
                    assignment: None,
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(external.clone()),
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/identity.json"))),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::LiveDisplayId(2),
                    live_display: None,
                    assignment: Some(WallpaperAssignment::Direct(template("/tmp/stale.json"))),
                    window_active: false,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();

        assert_eq!(
            model
                .record(&DisplayKey::Identity(external.clone()))
                .unwrap()
                .live_display,
            Some(display(2, external))
        );
        assert_eq!(
            model
                .record(&DisplayKey::LiveDisplayId(2))
                .unwrap()
                .live_display,
            None
        );
    }

    #[test]
    fn duplicate_connected_identity_matches_error_and_preserve_model() {
        let configured = DisplayIdentity {
            uuid: None,
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(9),
            unit_number: None,
            name: None,
        };
        let first = DisplayIdentity {
            uuid: None,
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(9),
            unit_number: Some(1),
            name: Some("first".to_string()),
        };
        let second = DisplayIdentity {
            uuid: None,
            vendor_id: Some(7),
            model_id: Some(8),
            serial_number: Some(9),
            unit_number: Some(2),
            name: Some("second".to_string()),
        };
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(configured),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/external.json"))),
            }],
        })
        .unwrap();
        let before = model.clone();

        let error = model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, first),
                    display(3, second),
                ],
            )
            .expect_err("duplicate connected display match should fail");

        match error {
            EngineError::InvalidInput(message) => {
                assert!(message.contains("multiple connected displays"));
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
        assert_eq!(model, before);
    }

    #[test]
    fn active_future_display_without_wallpaper_inherits_primary_on_first_connection() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![
                DisplayConfig {
                    selector: DisplaySelector::Primary,
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(external.clone()),
                    window_active: true,
                    wallpaper: None,
                },
            ],
        })
        .unwrap();

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();

        let future = model
            .record(&DisplayKey::Identity(external))
            .expect("future display should connect to existing config");
        assert_eq!(
            future.assignment,
            Some(WallpaperAssignment::Direct(template("/tmp/primary.json")))
        );
    }

    #[test]
    fn blank_primary_at_first_future_connection_prevents_later_auto_inherit() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: None,
            }],
        })
        .unwrap();

        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();
        assert_eq!(
            model
                .record(&DisplayKey::Identity(external.clone()))
                .expect("future display should connect")
                .assignment,
            None
        );

        model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Direct(template("/tmp/later-primary.json")),
            )
            .unwrap();
        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary"))],
            )
            .unwrap();
        model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .unwrap();

        assert_eq!(
            model
                .record(&DisplayKey::Identity(external))
                .expect("future display should reconnect")
                .assignment,
            None
        );
    }

    #[test]
    fn primary_switch_transfers_runtime_flags_between_primary_and_identity_records() {
        let primary_identity = identity("primary-a");
        let secondary_identity = identity("secondary-b");
        let shared = WallpaperAssignment::Direct(template("/tmp/shared.json"));
        let old_primary =
            DisplayDesc::with_identity(1, primary_identity.clone(), 0, 0, 3420, 2214, 2.0);
        let old_secondary =
            DisplayDesc::with_identity(3, secondary_identity.clone(), 3420, 0, 1920, 1080, 1.0);
        let new_primary =
            DisplayDesc::with_identity(3, secondary_identity.clone(), 0, 0, 1920, 1080, 1.0);
        let new_secondary =
            DisplayDesc::with_identity(1, primary_identity.clone(), -1710, 0, 3420, 2214, 2.0);
        let mut model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(old_primary),
                    assignment: Some(shared.clone()),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(primary_identity.clone()),
                    live_display: None,
                    assignment: Some(shared.clone()),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(secondary_identity.clone()),
                    live_display: Some(old_secondary),
                    assignment: Some(shared),
                    window_active: true,
                    runtime_open: true,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        let actions = model
            .refresh_connected(
                new_primary.clone(),
                vec![new_primary.clone(), new_secondary.clone()],
            )
            .unwrap();

        let primary = model
            .record(&DisplayKey::Primary)
            .expect("primary record should remain");
        assert_eq!(primary.live_display, Some(new_primary));
        assert!(primary.runtime_open);

        let new_secondary_record = model
            .record(&DisplayKey::Identity(primary_identity))
            .expect("old primary identity record should remain");
        assert_eq!(new_secondary_record.live_display, Some(new_secondary));
        assert!(new_secondary_record.runtime_open);

        let old_secondary_record = model
            .record(&DisplayKey::Identity(secondary_identity))
            .expect("new primary identity record should remain for future swaps");
        assert_eq!(old_secondary_record.live_display, None);
        assert!(!old_secondary_record.runtime_open);
        assert_eq!(
            actions,
            vec![
                DisplayAction::Rebuild(DisplayKey::Primary),
                DisplayAction::Rebuild(DisplayKey::Identity(identity("primary-a"))),
            ]
        );
    }

    #[test]
    fn mirror_assignment_follows_source_assignment() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
            }],
        })
        .unwrap();
        model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Direct(template("/tmp/primary.json")),
            )
            .unwrap();

        assert_eq!(
            model
                .resolved_assignment(&DisplayKey::Identity(external))
                .unwrap(),
            Some(WallpaperAssignment::Direct(template("/tmp/primary.json")))
        );
    }

    #[test]
    fn mirror_cycles_are_rejected() {
        let a = identity("a");
        let b = identity("b");
        let error = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![
                DisplayConfig {
                    selector: DisplaySelector::Identity(a.clone()),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Mirror(DisplaySelector::Identity(
                        b.clone(),
                    ))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(b),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Mirror(DisplaySelector::Identity(a))),
                },
            ],
        })
        .expect_err("cycle should fail");

        match error {
            EngineError::InvalidInput(message) => assert!(message.contains("mirror cycle")),
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn set_assignment_rejects_cycle_without_mutating_model() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/external.json"))),
            }],
        })
        .unwrap();
        let before = model.clone();

        let error = model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Mirror(DisplaySelector::Primary),
            )
            .expect_err("self-cycle should fail");

        match error {
            EngineError::InvalidInput(message) => assert!(message.contains("mirror cycle")),
            other => panic!("expected invalid input, got {other:?}"),
        }
        assert_eq!(model, before);
    }

    #[test]
    fn failed_refresh_from_inherited_mirror_cycle_keeps_previous_state() {
        let external = identity("external");
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();
        model
            .set_assignment(
                &DisplaySelector::Primary,
                WallpaperAssignment::Mirror(DisplaySelector::Identity(external.clone())),
            )
            .unwrap();
        let before = model.clone();

        let error = model
            .refresh_connected(
                display(1, identity("primary")),
                vec![
                    display(1, identity("primary")),
                    display(2, external.clone()),
                ],
            )
            .expect_err("inherited mirror cycle should fail");

        match error {
            EngineError::InvalidInput(message) => assert!(message.contains("mirror cycle")),
            other => panic!("expected invalid input, got {other:?}"),
        }
        assert_eq!(model, before);
    }

    #[test]
    fn active_connected_assigned_display_plans_open() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();

        let actions = model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary"))],
            )
            .unwrap();

        assert_eq!(actions, vec![DisplayAction::Open(DisplayKey::Primary)]);
    }

    #[test]
    fn plan_actions_returns_mirror_resolution_errors() {
        let external = identity("external");
        let model = DisplayStateModel {
            records: vec![
                DisplayRecord {
                    key: DisplayKey::Primary,
                    live_display: Some(display(1, identity("primary"))),
                    assignment: Some(WallpaperAssignment::Mirror(DisplaySelector::Identity(
                        external.clone(),
                    ))),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
                DisplayRecord {
                    key: DisplayKey::Identity(external.clone()),
                    live_display: Some(display(2, external.clone())),
                    assignment: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
                    window_active: true,
                    runtime_open: false,
                    primary_inheritance_consumed: false,
                },
            ],
        };

        let error = model
            .plan_actions()
            .expect_err("mirror cycle should fail during planning");

        match error {
            EngineError::InvalidInput(message) => assert!(message.contains("mirror cycle")),
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn active_already_open_assigned_display_plans_rebuild() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        let record = model.ensure_record(DisplayKey::Primary);
        record.live_display = Some(display(1, identity("primary")));
        record.runtime_open = true;

        assert_eq!(
            model.plan_actions().unwrap(),
            vec![DisplayAction::Rebuild(DisplayKey::Primary)]
        );
    }

    #[test]
    fn inactive_already_open_assigned_display_plans_rebuild() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: false,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        let record = model.ensure_record(DisplayKey::Primary);
        record.live_display = Some(display(1, identity("primary")));
        record.runtime_open = true;

        assert_eq!(
            model.plan_actions().unwrap(),
            vec![DisplayAction::Rebuild(DisplayKey::Primary)]
        );
    }

    #[test]
    fn refresh_preserves_inactive_existing_runtime() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: false,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        let record = model.ensure_record(DisplayKey::Primary);
        record.live_display = Some(display(1, identity("primary")));
        record.runtime_open = true;

        let actions = model
            .refresh_connected(
                display(1, identity("primary")),
                vec![display(1, identity("primary"))],
            )
            .unwrap();

        let record = model.record(&DisplayKey::Primary).unwrap();
        assert!(!record.window_active);
        assert!(record.runtime_open);
        assert_eq!(actions, vec![DisplayAction::Rebuild(DisplayKey::Primary)]);
    }

    #[test]
    fn destroy_window_closes_inactive_existing_runtime() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: false,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        let record = model.ensure_record(DisplayKey::Primary);
        record.live_display = Some(display(1, identity("primary")));
        record.runtime_open = true;

        let actions = model.destroy_window(&DisplaySelector::Primary).unwrap();

        assert_eq!(actions, vec![DisplayAction::Close(DisplayKey::Primary)]);
        assert!(!model.record(&DisplayKey::Primary).unwrap().runtime_open);
    }

    #[test]
    fn open_display_losing_assignment_or_live_display_plans_close() {
        let mut missing_assignment =
            DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();
        {
            let record = missing_assignment.ensure_record(DisplayKey::Primary);
            record.live_display = Some(display(1, identity("primary")));
            record.runtime_open = true;
        }

        assert_eq!(
            missing_assignment.plan_actions().unwrap(),
            vec![DisplayAction::Close(DisplayKey::Primary)]
        );

        let mut missing_live_display = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        missing_live_display
            .ensure_record(DisplayKey::Primary)
            .runtime_open = true;

        assert_eq!(
            missing_live_display.plan_actions().unwrap(),
            vec![DisplayAction::Close(DisplayKey::Primary)]
        );
    }

    #[test]
    fn inactive_connected_assigned_display_plans_no_action() {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Primary,
                window_active: false,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
            }],
        })
        .unwrap();
        model.ensure_record(DisplayKey::Primary).live_display =
            Some(display(1, identity("primary")));

        assert!(model.plan_actions().unwrap().is_empty());
    }

    fn no_pixels(id: u32, identity: DisplayIdentity) -> DisplayDesc {
        DisplayDesc::with_identity(id, identity, 1920, 0, 0, 0, 1.0)
    }

    /// A primary display and an external one, both assigned, active and with
    /// their runtimes open, the way the engine leaves them after an Apply.
    fn model_running_on_two_displays(external: &DisplayIdentity) -> DisplayStateModel {
        let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![
                DisplayConfig {
                    selector: DisplaySelector::Primary,
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/primary.json"))),
                },
                DisplayConfig {
                    selector: DisplaySelector::Identity(external.clone()),
                    window_active: true,
                    wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/external.json"))),
                },
            ],
        })
        .unwrap();
        let primary = display(1, identity("primary"));
        model
            .refresh_connected(primary.clone(), vec![primary, display(7, external.clone())])
            .unwrap();
        for record in &mut model.records {
            record.runtime_open = true;
        }
        model
    }

    #[test]
    fn a_running_display_that_reports_no_pixels_keeps_its_descriptor_and_runtime() {
        let external = identity("external");
        let key = DisplayKey::Identity(external.clone());
        let mut model = model_running_on_two_displays(&external);
        let primary = display(1, identity("primary"));
        let running = model.record(&key).unwrap().live_display.clone();
        assert_eq!(running, Some(display(7, external.clone())));

        // Dropping the display from the report instead leaves it without a
        // live descriptor, and the engine closes the runtime of such a record
        // and reloads the scene when the display returns.
        let mut dropped = model.clone();
        dropped
            .refresh_connected(primary.clone(), vec![primary.clone()])
            .unwrap();
        assert!(!dropped.record(&key).unwrap().should_have_runtime());

        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(7, external.clone())],
            )
            .unwrap();

        let record = model.record(&key).unwrap();
        assert!(record.should_have_runtime());
        assert_eq!(record.live_display, running);
        assert!(record.runtime_open);
        assert!(model.record(&DisplayKey::Primary).unwrap().runtime_open);
    }

    #[test]
    fn a_new_display_that_reports_no_pixels_gets_no_record_until_it_has_a_size() {
        let external = identity("external");
        let key = DisplayKey::Identity(external.clone());
        let primary = display(1, identity("primary"));

        // Not part of the configuration: no record appears for it at all.
        let mut unknown = DisplayStateModel::from_config(WallpaperEngineConfig::default()).unwrap();
        unknown
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary.clone()],
                &[no_pixels(7, external.clone())],
            )
            .unwrap();
        assert_eq!(unknown.records.len(), 1);

        // Configured but not yet connected: the record stays without a
        // descriptor, so nothing opens on it.
        let mut configured = DisplayStateModel::from_config(WallpaperEngineConfig {
            displays: vec![DisplayConfig {
                selector: DisplaySelector::Identity(external.clone()),
                window_active: true,
                wallpaper: Some(WallpaperAssignment::Direct(template("/tmp/external.json"))),
            }],
        })
        .unwrap();
        let actions = configured
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary.clone()],
                &[no_pixels(7, external.clone())],
            )
            .unwrap();
        assert!(configured.record(&key).unwrap().live_display.is_none());
        assert!(!actions.contains(&DisplayAction::Open(key.clone())));

        let actions = configured
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary, display(7, external.clone())],
                &[],
            )
            .unwrap();
        assert!(actions.contains(&DisplayAction::Open(key)));
    }

    #[test]
    fn transitional_matching_uses_identity_when_the_display_id_changed() {
        let external = identity("external");
        let key = DisplayKey::Identity(external.clone());
        let mut model = model_running_on_two_displays(&external);
        let primary = display(1, identity("primary"));
        let running = model.record(&key).unwrap().live_display.clone();

        // The same monitor came back under a new id and has no size yet.
        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(9, external.clone())],
            )
            .unwrap();

        let record = model.record(&key).unwrap();
        assert_eq!(record.live_display, running);
        assert!(record.runtime_open);
    }

    #[test]
    fn a_transitional_display_does_not_keep_a_different_display_that_went_away() {
        let external = identity("external");
        let key = DisplayKey::Identity(external.clone());
        let mut model = model_running_on_two_displays(&external);
        let primary = display(1, identity("primary"));

        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(9, identity("somebody-else"))],
            )
            .unwrap();

        let record = model.record(&key).unwrap();
        assert!(record.live_display.is_none());
        assert!(!record.runtime_open);
    }
}
