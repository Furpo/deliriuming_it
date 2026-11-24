//! Homer's get-up clip on a fitted body (ROADMAP M10: "get-up by animation off on fitted bodies").
//!
//! The Playroom's get-up clips (`dms_game::getup::Clips`) put Homer's 21 parts on the game's player skeleton, so their
//! frames come out in Homer's proportions. A body fitted to another model (`dms_fit`) has the same 21 parts, tree and
//! frame conventions, but its own lengths. [`Retarget`] turns the clip's frames into that body's:
//!
//! * each part's rotation is the clip's, turned by the (usually tiny) difference between the two bodies' frames for the
//!   part in their standing poses;
//! * positions are walked down the part tree from the pelvis with the fitted body's own offsets (the part's place in
//!   its parent's frame, from the standing pose), so limbs keep the model's lengths and feet are not pulled off;
//! * the pelvis follows the clip's pelvis, offset by how the two standing pelvises differ.

use delirium::prelude::*;
use dms_game::body::Body;

pub struct Retarget {
    parent: Vec<Option<usize>>,
    /// Per part: the fitted part's standing frame in Homer's (`homer^-1 * fitted`).
    turn: Vec<Quat>,
    /// Per part but the root: its offset in its parent's frame (fitted, standing), and Homer's.
    offset: Vec<Vec3>,
    homer_offset: Vec<Vec3>,
    /// The fitted pelvis from Homer's, in Homer's pelvis frame (standing, same spot).
    pelvis: Vec3,
    /// The fitted pelvis's standing height over the floor, and Homer's (m).
    pub height: (f32, f32),
}

impl Retarget {
    /// For the fitted `fit` against Homer's `homer`, both as their `placed` standing poses at the origin.
    pub fn new(homer: &Body, fit: &Body) -> Retarget {
        let (h, f) = (homer.placed(Vec3::ZERO, 0.0), fit.placed(Vec3::ZERO, 0.0));
        let n = h.len().min(f.len());
        let parent: Vec<Option<usize>> = (0..n).map(|k| fit.parts[k].parent).collect();
        let turn = (0..n).map(|k| (h[k].1.inverse() * f[k].1).normalize()).collect();
        let offset = (0..n)
            .map(|k| match parent[k] {
                Some(p) => f[p].1.inverse() * (f[k].0 - f[p].0),
                None => Vec3::ZERO,
            })
            .collect();
        let homer_offset = (0..n)
            .map(|k| match parent[k] {
                Some(p) => h[p].1.inverse() * (h[k].0 - h[p].0),
                None => Vec3::ZERO,
            })
            .collect();
        let pelvis = h[0].1.inverse() * (f[0].0 - h[0].0);
        Retarget { parent, turn, offset, homer_offset, pelvis, height: (f[0].0.z, h[0].0.z) }
    }

    /// The fitted body's frames for the clip's (`clip`: Homer's parts' frames, NM's frame).
    pub fn apply(&self, clip: &[Transform]) -> Vec<Transform> {
        let n = self.parent.len().min(clip.len());
        let mut out: Vec<Transform> = Vec::with_capacity(n);
        for k in 0..n {
            let rot = (clip[k].rotation * self.turn[k]).normalize();
            let pos = match self.parent[k] {
                Some(p) if p < k => out[p].translation + out[p].rotation * self.offset[k],
                _ => clip[0].translation + clip[0].rotation * self.pelvis,
            };
            out.push(Transform::from_translation(pos).with_rotation(rot));
        }
        out
    }

    /// Homer's frames for the fitted body's (`apply`'s inverse): the clip blends the lying pose in over its first
    /// moments in Homer's proportions, so he lies down there as the fitted body lies, and `apply` gives it back.
    pub fn to_homer(&self, fit: &[Transform]) -> Vec<Transform> {
        let n = self.parent.len().min(fit.len());
        let mut out: Vec<Transform> = Vec::with_capacity(n);
        for k in 0..n {
            let rot = (fit[k].rotation * self.turn[k].inverse()).normalize();
            let pos = match self.parent[k] {
                Some(p) if p < k => out[p].translation + out[p].rotation * self.homer_offset[k],
                _ => fit[0].translation - rot * self.pelvis,
            };
            out.push(Transform::from_translation(pos).with_rotation(rot));
        }
        out
    }
}
