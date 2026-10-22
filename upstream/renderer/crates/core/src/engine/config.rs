use crate::{DisplayIdentity, project::SceneTemplate};

// R2-CC1: to be written from spec

#[derive(Clone, Debug, PartialEq)]
pub enum WallpaperAssignment {
    Direct(SceneTemplate),
    Mirror(DisplaySelector),
}
