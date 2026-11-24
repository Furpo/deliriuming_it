//! Homer's get-up clip on a fitted body (ROADMAP M10: "get-up by animation off on fitted bodies", docs/adr/0037).
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
    /// How far the lowest point of each foot (`FEET`) is under its frame, as NM's `placed` takes it (radius + half
    /// length: what puts its stance's feet on the floor).
    foot: [f32; 2],
}

/// Left and right foot (NM's part order).
const FEET: [usize; 2] = [3, 6];
/// The floor lock works from this part of the standing pelvis height up (smoothly), and never moves a pose more than
/// MAX_PLANT (m).
const PLANT_FROM: f32 = 0.55;
const MAX_PLANT: f32 = 0.12;

impl Retarget {
    /// For the fitted `fit` against Homer's `homer`, both as their `placed` standing poses at the origin.
    pub fn new(homer: &Body, fit: &Body) -> Retarget {
        let parent = fit.parts.iter().map(|p| p.parent).collect();
        let foot = FEET.map(|k| fit.parts.get(k).map_or(0.0, |p| p.radius + p.half));
        Retarget::from_standing(parent, &homer.placed(Vec3::ZERO, 0.0), &fit.placed(Vec3::ZERO, 0.0), foot)
    }

    /// From the parts' parents (a parent comes before its children) and both bodies' standing frames, position and
    /// rotation per part, at the same spot facing the same way.
    pub fn from_standing(parent: Vec<Option<usize>>, h: &[(Vec3, Quat)], f: &[(Vec3, Quat)], foot: [f32; 2]) -> Retarget {
        let n = parent.len().min(h.len()).min(f.len());
        let parent: Vec<Option<usize>> = parent.into_iter().take(n).collect();
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
        Retarget { parent, turn, offset, homer_offset, pelvis, height: (f[0].0.z, h[0].0.z), foot }
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

    /// The floor lock: the clip's last frames stand on straighter legs than NM's stance, and the retarget's feet end a
    /// little above the floor, so NM takes a body that is falling the last centimetres and loses its balance. From
    /// PLANT_FROM of the standing pelvis height up, the pose is lowered (never raised, by at most MAX_PLANT) till the
    /// lower foot is where NM's stance has it over `floor` (NM's frame, m).
    pub fn plant(&self, frames: &mut [Transform], floor: f32) {
        if frames.len() <= FEET[1] {
            return;
        }
        let low = FEET.iter().zip(self.foot).map(|(&k, e)| frames[k].translation.z - e).fold(f32::MAX, f32::min);
        let up = (((frames[0].translation.z - floor) / self.height.0 - PLANT_FROM) / (0.85 - PLANT_FROM)).clamp(0.0, 1.0);
        let shift = (floor - low).clamp(-MAX_PLANT, 0.0) * up * up * (3.0 - 2.0 * up);
        for f in frames.iter_mut() {
            f.translation.z += shift;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// NM's part tree (a parent before its children): pelvis, left leg, right leg, spine, neck, head, arms.
    const PARENT: [Option<usize>; 21] = [
        None, Some(0), Some(1), Some(2), Some(0), Some(4), Some(5), Some(0), Some(7), Some(8), Some(9), Some(10), Some(11), Some(10),
        Some(13), Some(14), Some(15), Some(10), Some(17), Some(18), Some(19),
    ];

    /// A small deterministic generator (no crate for it).
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> f32 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((self.0 >> 40) as f32) / (1u64 << 24) as f32
        }
        fn quat(&mut self, spread: f32) -> Quat {
            Quat::from_euler(EulerRot::XYZ, (self.next() - 0.5) * spread, (self.next() - 0.5) * spread, (self.next() - 0.5) * spread)
        }
        fn vec(&mut self, scale: f32) -> Vec3 {
            Vec3::new(self.next() - 0.5, self.next() - 0.5, self.next() - 0.5) * scale
        }
    }

    /// A standing body: random small rotations and offsets walked down the tree.
    fn body(rng: &mut Rng, rot_spread: f32, scale: f32) -> Vec<(Vec3, Quat)> {
        let mut out: Vec<(Vec3, Quat)> = Vec::new();
        for k in 0..21 {
            let (pos, rot) = match PARENT[k] {
                Some(p) => (out[p].0 + out[p].1 * rng.vec(scale), (out[p].1 * rng.quat(rot_spread)).normalize()),
                None => (Vec3::new(0.0, 0.0, 1.0), rng.quat(rot_spread)),
            };
            out.push((pos, rot));
        }
        out
    }

    /// A pose of a body: its parts' rotations as given, positions walked with the body's own offsets from `root`.
    fn pose(stand: &[(Vec3, Quat)], rots: &[Quat], root: Vec3) -> Vec<Transform> {
        let mut out: Vec<Transform> = Vec::new();
        for k in 0..21 {
            let pos = match PARENT[k] {
                Some(p) => {
                    let off = stand[p].1.inverse() * (stand[k].0 - stand[p].0);
                    out[p].translation + out[p].rotation * off
                }
                None => root,
            };
            out.push(Transform::from_translation(pos).with_rotation(rots[k]));
        }
        out
    }

    fn close(a: &[Transform], b: &[Transform], what: &str) {
        for (k, (x, y)) in a.iter().zip(b).enumerate() {
            assert!((x.translation - y.translation).length() < 1e-4, "{what}: part {k} at {} against {}", x.translation, y.translation);
            assert!(x.rotation.angle_between(y.rotation) < 1e-3, "{what}: part {k} turned {}", x.rotation.angle_between(y.rotation));
        }
    }

    fn standing(s: &[(Vec3, Quat)]) -> Vec<Transform> {
        s.iter().map(|&(p, q)| Transform::from_translation(p).with_rotation(q)).collect()
    }

    #[test]
    fn homer_standing_gives_the_fitted_standing_pose() {
        let mut rng = Rng(1);
        let (h, f) = (body(&mut rng, 0.2, 0.3), body(&mut rng, 0.2, 0.35));
        let r = Retarget::from_standing(PARENT.to_vec(), &h, &f, [0.1, 0.1]);
        close(&r.apply(&standing(&h)), &standing(&f), "apply(homer standing)");
        close(&r.to_homer(&standing(&f)), &standing(&h), "to_homer(fitted standing)");
    }

    #[test]
    fn the_two_directions_undo_each_other() {
        let mut rng = Rng(7);
        let (h, f) = (body(&mut rng, 0.2, 0.3), body(&mut rng, 0.2, 0.35));
        let r = Retarget::from_standing(PARENT.to_vec(), &h, &f, [0.1, 0.1]);
        // A clip as Homer would be in it: any rotations, his own offsets.
        let rots: Vec<Quat> = (0..21).map(|_| rng.quat(3.0)).collect();
        let clip = pose(&h, &rots, Vec3::new(0.4, -0.2, 0.15));
        close(&r.to_homer(&r.apply(&clip)), &clip, "to_homer(apply(clip))");
        // A pose of the fitted body.
        let rots: Vec<Quat> = (0..21).map(|_| rng.quat(3.0)).collect();
        let fit = pose(&f, &rots, Vec3::new(-0.3, 0.5, 0.2));
        close(&r.apply(&r.to_homer(&fit)), &fit, "apply(to_homer(fitted pose))");
    }

    #[test]
    fn the_fitted_limbs_keep_their_own_lengths() {
        let mut rng = Rng(11);
        let (h, f) = (body(&mut rng, 0.2, 0.3), body(&mut rng, 0.2, 0.6));
        let r = Retarget::from_standing(PARENT.to_vec(), &h, &f, [0.1, 0.1]);
        let rots: Vec<Quat> = (0..21).map(|_| rng.quat(3.0)).collect();
        let out = r.apply(&pose(&h, &rots, Vec3::ZERO));
        for k in 1..21 {
            let p = PARENT[k].unwrap();
            let (want, got) = ((f[k].0 - f[p].0).length(), (out[k].translation - out[p].translation).length());
            assert!((want - got).abs() < 1e-4, "part {k}: {got} against {want}");
        }
    }

    #[test]
    fn the_floor_lock_lowers_a_floating_stand_and_leaves_the_rest() {
        let mut rng = Rng(5);
        let (h, f) = (body(&mut rng, 0.1, 0.3), body(&mut rng, 0.1, 0.3));
        // The fitted pelvis stands 1 m over its feet's floor (a made-up `placed` pose); each foot reaches 0.1 m under its frame.
        let mut f = f;
        f[0].0 = Vec3::new(0.0, 0.0, 1.0);
        let r = Retarget::from_standing(PARENT.to_vec(), &h, &f, [0.1, 0.1]);
        let pose = |pelvis: f32, foot: f32| {
            let mut fr = vec![Transform::from_translation(Vec3::new(0.0, 0.0, 0.5)); 21];
            fr[0].translation.z = pelvis;
            fr[3].translation.z = foot;
            fr[6].translation.z = foot;
            fr
        };
        // Standing 5 cm above the floor (feet at 0.15, their bound at 0.05): it comes down onto it.
        let mut up = pose(1.05, 0.15);
        r.plant(&mut up, 0.0);
        assert!((up[0].translation.z - 1.0).abs() < 1e-5 && (up[3].translation.z - 0.10).abs() < 1e-5, "{:?}", up[0].translation);
        // Never raised: feet already under the floor.
        let mut under = pose(1.0, 0.05);
        r.plant(&mut under, 0.0);
        assert!((under[0].translation.z - 1.0).abs() < 1e-6);
        // Lying (the pelvis low): untouched.
        let mut lying = pose(0.2, 0.15);
        r.plant(&mut lying, 0.0);
        assert!((lying[0].translation.z - 0.2).abs() < 1e-6);
        // Never by more than MAX_PLANT.
        let mut far = pose(1.5, 0.6);
        r.plant(&mut far, 0.0);
        assert!((far[0].translation.z - (1.5 - MAX_PLANT)).abs() < 1e-5);
    }
}
