"""Builds a Ringside fighter from MakeHuman (MPFB 2) assets, rigged to the game's skeleton.

Run headless (Blender 5.2 with the MPFB extension and the CC0 MakeHuman system assets):

    Blender -b --python tools/mpfb/build_fighter.py -- tools/mpfb/fighters/jin.json [--blend out.blend]

Output: assets/characters/mh/<id>/<id>.gltf (+ .bin and textures), see docs/graphics-plan.md
phase 2. What it does:

1. Creates the MakeHuman body from the fighter's macros (gender, age, muscle, ...) and bakes
   them, adds MPFB's game-engine rig, then eyes, eyebrows, eyelashes, hair, teeth, tongue.
2. Poses the limbs into the game skeleton's rest pose (a T-pose; MakeHuman stands in an
   A-pose) by turning each limb bone to the matching game bone's direction, twists the arms
   so the palms face down and the legs so the feet point forward, and bakes that as the rest
   pose. The spine, neck, head and clavicles keep MakeHuman's posture: the animations only
   need the limbs to match.
3. Bakes the game's face shapes (blink, squint, brow_down, brow_up, jaw_open, smile,
   grimace) from MakeHuman's expression units, onto the body and refitted onto the eyebrows,
   lashes, teeth and tongue; and the gaze shapes (look_left/right/up/down) onto the eyes.
4. Scales the figure so its hips stand at the game skeleton's hip height, rebuilds the game
   skeleton (assets/characters/base/Superhero_Male_FullBody.gltf) with every bone at the new
   body's joint but the game bone's own orientation, so the existing animation clips play
   unchanged, and rebinds the meshes to it.
5. Removes MakeHuman's helper geometry, subdivides the body once, gives every mesh a plain
   glTF material named the way scripts/fighter/fighter_model.gd expects (MI_Superhero*,
   MI_Hair*, MI_Eyes*), and exports glTF.
"""
import bpy
import json
import math
import os
import shutil
import sys

from mathutils import Matrix, Quaternion, Vector

from bl_ext.blender_org.mpfb.services.humanservice import HumanService
from bl_ext.blender_org.mpfb.services.targetservice import TargetService
from bl_ext.blender_org.mpfb.services.rigservice import RigService
from bl_ext.blender_org.mpfb.services.clothesservice import ClothesService
from bl_ext.blender_org.mpfb.services.exportservice import ExportService
from bl_ext.blender_org.mpfb.services.locationservice import LocationService
from bl_ext.blender_org.mpfb.entities.clothes.mhclo import Mhclo

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GAME_SKELETON = os.path.join(REPO, "assets/characters/base/Superhero_Male_FullBody.gltf")
import bl_ext.blender_org.mpfb as _mpfb
MPFB_UNITS = os.path.join(os.path.dirname(_mpfb.__file__), "data", "targets", "expression", "units")

# Limb bones turned to the game skeleton's directions, parents first.
ARM = ["upperarm", "lowerarm", "hand"]
FINGERS = [f"{f}_0{i}" for f in ["thumb", "index", "middle", "ring", "pinky"] for i in (1, 2, 3)]
LEG = ["thigh", "calf"]
FOOT = ["foot", "ball"]

# Game face shape -> MakeHuman expression units and weights.
FACE_SHAPES = {
    "blink": {"eye-left-closure": 1.0, "eye-right-closure": 1.0},
    "squint": {"eye-left-slit": 1.0, "eye-right-slit": 1.0},
    "brow_down": {"eyebrows-left-down": 1.0, "eyebrows-right-down": 1.0},
    "brow_up": {"eyebrows-left-up": 1.0, "eyebrows-right-up": 1.0, "eyebrows-left-inner-up": 0.4, "eyebrows-right-inner-up": 0.4},
    "jaw_open": {"mouth-open": 1.0},
    "smile": {"mouth-corner-puller": 1.0, "mouth-elevation": 0.2},
    "grimace": {"mouth-depression-retraction": 0.8, "nose-left-elevation": 0.5, "nose-right-elevation": 0.5},
}
# Gaze: (axis, radians) at weight 1. The face looks along -Y; +X is the character's left.
GAZE_SHAPES = {
    "look_left": ("Z", 0.35),
    "look_right": ("Z", -0.35),
    "look_up": ("X", -0.20),
    "look_down": ("X", 0.25),
}


def log(*args):
    print("BUILD", *args, flush=True)


def user_data(*parts):
    return os.path.join(LocationService.get_user_data(), *parts)


def asset_mhclo(kind, name):
    folder = user_data(kind, name)
    for f in os.listdir(folder):
        if f.endswith(".mhclo"):
            return os.path.join(folder, f)
    raise FileNotFoundError(folder)


def clear_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for block in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images, bpy.data.actions):
        for item in list(block):
            block.remove(item)


def set_active(obj):
    bpy.ops.object.mode_set(mode="OBJECT") if bpy.context.object and bpy.context.object.mode != "OBJECT" else None
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


# ---- 1. the human ----

def make_human(spec):
    macros = dict(spec["macros"])
    race = macros.pop("race")
    detail = TargetService.get_default_macro_info_dict()
    detail.update(macros)
    detail["race"] = race
    basemesh = HumanService.create_human(macro_detail_dict=detail)
    TargetService.bake_targets(basemesh)
    rig = HumanService.add_builtin_rig(basemesh, "game_engine")
    pieces = {}
    for kind, folder in [("eyes", "eyes"), ("eyebrows", "eyebrows"), ("eyelashes", "eyelashes"), ("hair", "hair"), ("teeth", "teeth"), ("tongue", "tongue")]:
        name = "low-poly" if kind == "eyes" else spec[kind] # one textured sphere per eye
        mhclo_path = asset_mhclo(folder, name)
        obj = HumanService.add_mhclo_asset(mhclo_path, basemesh, asset_type=kind.capitalize(), subdiv_levels=0)
        obj.name = kind
        pieces[kind] = (obj, mhclo_path)
    log("human", len(basemesh.data.vertices), "verts; pieces", list(pieces))
    return basemesh, rig, pieces


# ---- 2. pose the limbs into the game's rest pose ----

def game_bone_dirs():
    """Imports the game skeleton and returns {bone: (head, direction, length, roll matrix)} plus the armature."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=GAME_SKELETON, bone_heuristic="BLENDER")
    new = [o for o in bpy.data.objects if o not in before]
    arm = [o for o in new if o.type == "ARMATURE"][0]
    for o in new:
        if o.type != "ARMATURE":
            bpy.data.objects.remove(o, do_unlink=True)
    arm.name = "GameSkeleton"
    bones = {}
    for b in arm.data.bones:
        m = arm.matrix_world @ b.matrix_local
        head = arm.matrix_world @ b.head_local
        tail = arm.matrix_world @ b.tail_local
        bones[b.name] = {"head": head.copy(), "dir": (tail - head).normalized(), "len": (tail - head).length, "matrix": m.copy()}
    return arm, bones


def rotate_pose_bone(rig, name, rot, pivot):
    """Rotates pose bone `name` by world rotation `rot` about world point `pivot`."""
    pb = rig.pose.bones[name]
    world = rig.matrix_world @ pb.matrix
    world = Matrix.Translation(pivot) @ rot.to_matrix().to_4x4() @ Matrix.Translation(-pivot) @ world
    pb.matrix = rig.matrix_world.inverted() @ world
    bpy.context.view_layer.update()


def pose_head_tail(rig, name):
    pb = rig.pose.bones[name]
    return rig.matrix_world @ pb.head, rig.matrix_world @ pb.tail


def align(rig, name, target_dir):
    head, tail = pose_head_tail(rig, name)
    rot = (tail - head).normalized().rotation_difference(target_dir)
    rotate_pose_bone(rig, name, rot, head)


def twist(rig, name, axis_point, axis_dir, current, target):
    """Turns bone `name` about the axis through axis_point along axis_dir so that `current`
    (a vector, projected off the axis) lines up with `target`."""
    a = axis_dir.normalized()
    c = (current - a * current.dot(a)).normalized()
    t = (target - a * target.dot(a)).normalized()
    angle = math.atan2(a.dot(c.cross(t)), c.dot(t))
    rotate_pose_bone(rig, name, Quaternion(a, angle), axis_point)


def pose_to_game(rig, game):
    set_active(rig)
    bpy.ops.object.mode_set(mode="POSE")
    for side in ("l", "r"):
        for b in ARM:
            align(rig, f"{b}_{side}", game[f"{b}_{side}"]["dir"])
        # Palms: the index-to-pinky knuckle line, as on the game skeleton.
        head, _ = pose_head_tail(rig, f"upperarm_{side}")
        knuckles = pose_head_tail(rig, f"pinky_01_{side}")[0] - pose_head_tail(rig, f"index_01_{side}")[0]
        target = game[f"pinky_01_{side}"]["head"] - game[f"index_01_{side}"]["head"]
        twist(rig, f"upperarm_{side}", head, game[f"upperarm_{side}"]["dir"], knuckles, target)
        for b in FINGERS:
            align(rig, f"{b}_{side}", game[f"{b}_{side}"]["dir"])
        for b in LEG:
            align(rig, f"{b}_{side}", game[f"{b}_{side}"]["dir"])
        # Feet forward: twist the leg so the foot's line matches.
        hip, _ = pose_head_tail(rig, f"thigh_{side}")
        f_head, f_tail = pose_head_tail(rig, f"foot_{side}")
        twist(rig, f"thigh_{side}", hip, game[f"thigh_{side}"]["dir"], f_tail - f_head, game[f"foot_{side}"]["dir"])
        for b in FOOT:
            align(rig, f"{b}_{side}", game[f"{b}_{side}"]["dir"])
    bpy.ops.object.mode_set(mode="OBJECT")
    RigService.apply_pose_as_rest_pose(rig)
    log("posed to the game rest pose")


# ---- 3. face and gaze shapes ----

def expression_target(race, unit):
    path = os.path.join(MPFB_UNITS, race, unit + ".target.gz")
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    return path


def bake_face_shapes(basemesh, pieces, race):
    set_active(basemesh)
    if not basemesh.data.shape_keys:
        basemesh.shape_key_add(name="Basis", from_mix=False)
    for shape, units in FACE_SHAPES.items():
        loaded = []
        for unit, weight in units.items():
            key_name = f"u_{unit}"
            TargetService.load_target(basemesh, expression_target(race, unit), weight=weight, name=key_name)
            loaded.append(key_name)
        mixed = basemesh.shape_key_add(name=shape, from_mix=True)
        for key_name in loaded:
            basemesh.shape_key_remove(basemesh.data.shape_keys.key_blocks[key_name])
        mixed.value = 0.0
    keys = basemesh.data.shape_keys.key_blocks
    # The face pieces follow each shape: fit them to the body with that shape on, record.
    for kind in ("eyebrows", "eyelashes", "teeth", "tongue"):
        obj, mhclo_path = pieces[kind]
        mhclo = Mhclo()
        mhclo.load(mhclo_path)
        mhclo.clothes = obj
        recorded = {}
        for shape in FACE_SHAPES:
            for k in keys:
                k.value = 1.0 if k.name == shape else 0.0
            ClothesService.fit_clothes_to_human(obj, basemesh, mhclo, set_parent=False)
            recorded[shape] = [v.co.copy() for v in obj.data.vertices]
        for k in keys:
            k.value = 0.0
        ClothesService.fit_clothes_to_human(obj, basemesh, mhclo, set_parent=False)
        obj.shape_key_add(name="Basis", from_mix=False)
        for shape, coords in recorded.items():
            key = obj.shape_key_add(name=shape, from_mix=False)
            for i, co in enumerate(coords):
                key.data[i].co = co
    log("face shapes", list(FACE_SHAPES))


def bake_gaze_shapes(eyes):
    """Each eyeball turns about its own centre (the mesh's two halves, by X sign)."""
    mesh = eyes.data
    halves = {"l": [v.index for v in mesh.vertices if v.co.x > 0], "r": [v.index for v in mesh.vertices if v.co.x <= 0]}
    centres = {}
    for side, idx in halves.items():
        lo = Vector((min(mesh.vertices[i].co.x for i in idx), min(mesh.vertices[i].co.y for i in idx), min(mesh.vertices[i].co.z for i in idx)))
        hi = Vector((max(mesh.vertices[i].co.x for i in idx), max(mesh.vertices[i].co.y for i in idx), max(mesh.vertices[i].co.z for i in idx)))
        centres[side] = (lo + hi) / 2
    if not mesh.shape_keys:
        eyes.shape_key_add(name="Basis", from_mix=False)
    basis = mesh.shape_keys.key_blocks["Basis"]
    for shape, (axis, angle) in GAZE_SHAPES.items():
        key = eyes.shape_key_add(name=shape, from_mix=False)
        rot = Matrix.Rotation(angle, 3, axis)
        for side, idx in halves.items():
            c = centres[side]
            for i in idx:
                key.data[i].co = c + rot @ (basis.data[i].co - c)
    log("gaze shapes", list(GAZE_SHAPES))


# ---- 4. scale and the game skeleton ----

def scale_to_game(objects, rig, game):
    """Scales everything about the origin so the hips stand at the game skeleton's height.
    Each object is unparented first and scaled on its own: applying scale through a parent
    scales the children twice, which leaves bones and skin at different sizes (curled
    fingers then turn about the wrong pivots)."""
    hip = (rig.matrix_world @ rig.data.bones["thigh_l"].head_local).z
    s = game["thigh_l"]["head"].z / hip
    for o in objects:
        world = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = world
    for o in objects + [rig]:
        o.matrix_world = Matrix.Scale(s, 4) @ o.matrix_world
        set_active(o)
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    log("scaled by %.3f (hips %.3f -> %.3f)" % (s, hip, hip * s))
    return s


def build_game_skeleton(game_arm, rig, objects):
    """Moves every game bone to the matching MakeHuman joint, keeping its orientation."""
    mh = {b.name.lower(): (rig.matrix_world @ b.head_local, (rig.matrix_world @ b.tail_local - rig.matrix_world @ b.head_local).length) for b in rig.data.bones}
    set_active(game_arm)
    bpy.ops.object.mode_set(mode="EDIT")
    edit = game_arm.data.edit_bones
    inv = game_arm.matrix_world.inverted()
    order = []

    def walk(b):
        order.append(b.name)
        for c in b.children:
            walk(c)
    for b in edit:
        if b.parent is None:
            walk(b)
    original = {b.name: (b.head.copy(), b.tail.copy(), b.roll) for b in edit}
    for name in order:
        b = edit[name]
        head0, tail0, roll0 = original[name]
        direction = (tail0 - head0).normalized()
        key = name.lower()
        if key in mh:
            head, length = mh[key]
            head = inv @ head
        else: # a leaf bone (fingertip, toe tip, root): keep its offset from the parent's new head
            parent = b.parent
            if parent is None:
                head, length = head0, (tail0 - head0).length
            else:
                p_head0 = original[parent.name][0]
                scale = (parent.tail - parent.head).length / max((original[parent.name][1] - p_head0).length, 1e-6)
                head = parent.head + (head0 - p_head0) * scale
                length = (tail0 - head0).length * scale
        b.head = head
        b.tail = head + direction * max(length, 0.01)
        b.roll = roll0
    bpy.ops.object.mode_set(mode="OBJECT")
    for o in objects:
        for g in o.vertex_groups:
            if g.name == "head":
                g.name = "Head"
            elif g.name == "Root":
                g.name = "root"
        armature_mods = [m for m in o.modifiers if m.type == "ARMATURE"]
        if not armature_mods: # the outfit pieces are new objects
            armature_mods = [o.modifiers.new("Armature", "ARMATURE")]
        for m in armature_mods:
            m.object = game_arm
        o.parent = game_arm
        o.matrix_parent_inverse = game_arm.matrix_world.inverted()
        assert (o.matrix_world.to_scale() - Vector((1, 1, 1))).length < 1e-4, o.name
    bpy.data.objects.remove(rig, do_unlink=True)
    game_arm.name = "Armature"
    log("game skeleton rebuilt:", len(order), "bones")



# ---- 4b. the outfit: cut from the body's own surface ----

import bmesh
from mathutils import noise


def landmarks(rig):
    def head(name):
        return rig.matrix_world @ rig.data.bones[name].head_local
    lm = {
        "waist_z": head("spine_01").z - 0.005,
        "crotch_z": head("thigh_l").z - 0.075,
        "knee_z": head("calf_l").z,
        "ankle_z": head("foot_l").z,
        "neck_z": head("neck_01").z,
        "chest_z": head("spine_03").z,
        "shoulder_x": head("upperarm_l").x,
        "elbow_x": head("lowerarm_l").x,
        "wrist_x": head("hand_l").x,
    }
    lm["sleeve_x"] = lm["elbow_x"] + 0.88 * (lm["wrist_x"] - lm["elbow_x"])
    lm["v_bottom"] = lm["chest_z"] + 0.03
    return lm


def v_half(lm, z):
    t = max(0.0, min(1.0, (z - lm["v_bottom"]) / max(lm["neck_z"] - lm["v_bottom"], 0.01)))
    return 0.012 + 0.07 * t


def in_jacket(lm, c, margin=0.0):
    if not (lm["crotch_z"] + 0.03 + margin <= c.z <= lm["neck_z"] - 0.004 - margin):
        return False
    if abs(c.x) > lm["sleeve_x"] - margin:
        return False
    if c.y < 0 and c.z > lm["v_bottom"] - margin and abs(c.x) < v_half(lm, c.z) + margin:
        return False # the V-neck
    return True


def in_trousers(lm, c, margin=0.0):
    return lm["ankle_z"] + 0.035 + margin <= c.z <= lm["waist_z"] + 0.012 - margin and abs(c.x) < lm["shoulder_x"]


def copy_region(basemesh, name, keep):
    """A new object holding the body faces whose centre passes `keep`, with the body's
    vertex groups (so the garment inherits the skin's weights) and no shape keys."""
    me = basemesh.data.copy()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for g in basemesh.vertex_groups:
        obj.vertex_groups.new(name=g.name)
    if me.shape_keys:
        set_active(obj)
        obj.shape_key_clear()
    body_group = basemesh.vertex_groups["body"].index
    bm = bmesh.new()
    bm.from_mesh(me)
    deform = bm.verts.layers.deform.active
    doomed = []
    for f in bm.faces:
        real = all(body_group in v[deform] for v in f.verts)
        if not real or not keep(f.calc_center_median()):
            doomed.append(f)
    bmesh.ops.delete(bm, geom=doomed, context="FACES")
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    relax_boundary(bm)
    bm.to_mesh(me)
    bm.free()
    obj.matrix_world = basemesh.matrix_world.copy()
    return obj


def relax_boundary(bm, iterations=6):
    """The cut follows the body's faces, so its edge steps; slide the edge vertices toward
    their two edge neighbours until the hems and the V run as smooth curves."""
    edge = [v for v in bm.verts if v.is_boundary]
    for _ in range(iterations):
        moved = {}
        for v in edge:
            ring = [e.other_vert(v) for e in v.link_edges if e.is_boundary]
            if len(ring) == 2:
                moved[v] = v.co * 0.4 + (ring[0].co + ring[1].co) * 0.3
        for v, co in moved.items():
            v.co = co


def subdivide(obj, levels=1):
    set_active(obj)
    m = obj.modifiers.new("Sub", "SUBSURF")
    m.levels = levels
    bpy.ops.object.modifier_apply(modifier=m.name)


def fold(p, axis, scale_along, scale_across):
    """Fabric folds: noise stretched along the limb (axis) so the ridges run with it."""
    q = Vector((p.x * (scale_along if axis == "X" else scale_across),
                p.y * scale_across,
                p.z * (scale_along if axis == "Z" else scale_across)))
    return noise.noise(q) + 0.5 * noise.noise(q * 2.03)


def shape_garment(obj, offset, folds, collar=None):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    for v in bm.verts:
        v.co += v.normal * (offset(v.co) + folds(v.co))
    bm.normal_update()
    if collar is not None:
        collar(bm)
    # Hems: the open edges turned inward, so the cloth shows a thickness.
    bm.normal_update()
    boundary = [e for e in bm.edges if e.is_boundary]
    ret = bmesh.ops.extrude_edge_only(bm, edges=boundary)
    for v in [g for g in ret["geom"] if isinstance(g, bmesh.types.BMVert)]:
        v.co -= v.normal * 0.007
    bm.normal_update()
    bm.to_mesh(obj.data)
    bm.free()


def ring(c, z0, around, width):
    """Gaussian bump around height (or x) `around`."""
    return math.exp(-((c - around) / width) ** 2)


def make_outfit(basemesh, rig, spec):
    lm = landmarks(rig)
    log("landmarks", {k: round(v, 3) for k, v in lm.items()})
    seed = hash(spec["id"]) % 1000

    jacket = copy_region(basemesh, "jacket", lambda c: in_jacket(lm, c))
    subdivide(jacket)

    def jacket_offset(c):
        base = 0.016
        if abs(c.x) > lm["shoulder_x"]: # sleeves hang loose, widest at the cuff
            t = (abs(c.x) - lm["shoulder_x"]) / max(lm["sleeve_x"] - lm["shoulder_x"], 0.01)
            base = 0.022 + 0.018 * t
        elif c.z < lm["waist_z"]: # the skirt below the belt sits over the trousers
            base = 0.03 + 0.02 * (lm["waist_z"] - c.z) / 0.12
        return base

    def jacket_folds(c):
        if abs(c.x) > lm["shoulder_x"]:
            f = 0.0055 * fold(c + Vector((seed, 0, 0)), "X", 3.0, 28.0)
            f += 0.006 * ring(abs(c.x), 0, lm["elbow_x"], 0.04) * math.sin(abs(c.x) * 220.0)
            return f
        return 0.0035 * fold(c + Vector((0, seed, 0)), "Z", 4.0, 18.0)
    collar_obj = []

    def collar(bm):
        collar_obj.append(make_collar(jacket, bm, lm))
    shape_garment(jacket, jacket_offset, jacket_folds, collar)

    trousers = copy_region(basemesh, "trousers", lambda c: in_trousers(lm, c))
    subdivide(trousers)

    def trousers_offset(c):
        if c.z > lm["crotch_z"]:
            return 0.014
        t = (lm["crotch_z"] - c.z) / max(lm["crotch_z"] - lm["ankle_z"], 0.01)
        return 0.018 + 0.035 * t ** 1.4 # wide legs that flare toward the ankle

    def trousers_folds(c):
        f = 0.006 * fold(c + Vector((0, 0, seed)), "Z", 2.5, 24.0)
        f += 0.007 * ring(c.z, 0, lm["knee_z"], 0.05) * math.sin(c.z * 200.0)
        f += 0.005 * ring(c.z, 0, lm["ankle_z"] + 0.06, 0.04) * math.sin(c.z * 260.0)
        return f
    shape_garment(trousers, trousers_offset, trousers_folds)

    jacket.data.materials.append(bpy.data.materials.new("MI_Cloth_main"))
    trousers.data.materials.append(bpy.data.materials["MI_Cloth_main"])

    belt = make_belt(basemesh, lm)
    log("outfit: jacket %d, trousers %d, belt %d faces" % (len(jacket.data.polygons), len(trousers.data.polygons), len(belt.data.polygons)))
    return [jacket, trousers, belt] + collar_obj, lm


def make_collar(jacket, bm, lm, width=0.042):
    """The collar band in the trim colour: a strip of constant width laid on the jacket
    along the neckline (the highest open edge loop), carrying the jacket's weights."""
    deform = bm.verts.layers.deform.active
    boundary = {v for v in bm.verts if v.is_boundary}
    loops, seen = [], set()
    for start in boundary:
        if start in seen:
            continue
        loop, v, prev = [], start, None
        while v is not None and v not in seen:
            seen.add(v)
            loop.append(v)
            nxt = [e.other_vert(v) for e in v.link_edges if e.is_boundary and e.other_vert(v) is not prev and e.other_vert(v) not in seen]
            prev, v = v, (nxt[0] if nxt else None)
        loops.append(loop)
    neck = max(loops, key=lambda lp: sum(v.co.z for v in lp) / len(lp))
    me = bpy.data.meshes.new("collar")
    cbm = bmesh.new()
    cdeform = cbm.verts.layers.deform.verify()
    rows = []
    for v in neck:
        inward = sum(((f.calc_center_median() - v.co) for f in v.link_faces), Vector()).normalized()
        n = v.normal
        inward = (inward - n * inward.dot(n)).normalized()
        a = cbm.verts.new(v.co + n * 0.003 - inward * 0.004)
        b = cbm.verts.new(v.co + n * 0.004 + inward * width)
        for vv in (a, b):
            for g, w in v[deform].items():
                vv[cdeform][g] = w
        rows.append((a, b))
    for i in range(len(rows)):
        a0, b0 = rows[i]
        a1, b1 = rows[(i + 1) % len(rows)]
        cbm.faces.new((a0, a1, b1, b0))
    cbm.normal_update()
    cbm.to_mesh(me)
    cbm.free()
    obj = bpy.data.objects.new("collar", me)
    bpy.context.scene.collection.objects.link(obj)
    for g in jacket.vertex_groups:
        obj.vertex_groups.new(name=g.name)
    me.materials.append(bpy.data.materials.new("MI_Cloth_trim"))
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for k, li in enumerate(poly.loop_indices):
            uv.data[li].uv = (poly.index * 0.05 + (1 if k in (1, 2) else 0) * 0.05, 0.0 if k in (0, 1) else 0.3)
    return obj


def make_belt(basemesh, lm):
    """A band around the waist over the jacket, a knot at the front and two hanging ends."""
    z = lm["waist_z"]
    pts = [basemesh.matrix_world @ v.co for v in basemesh.data.vertices if abs((basemesh.matrix_world @ v.co).z - z) < 0.02]
    cy = sum(p.y for p in pts) / max(len(pts), 1)
    n = 48
    radius = [0.0] * n
    for p in pts:
        a = math.atan2(p.y - cy, p.x)
        i = int((a + math.pi) / (2 * math.pi) * n) % n
        radius[i] = max(radius[i], math.hypot(p.x, p.y - cy))
    for i in range(n): # fill gaps from neighbours
        if radius[i] == 0.0:
            radius[i] = max(radius[(i - 1) % n], radius[(i + 1) % n])
    bm = bmesh.new()
    half_w, thick, out = 0.022, 0.006, 0.05
    rows = []
    for i in range(n):
        a = -math.pi + (i + 0.5) / n * 2 * math.pi
        d = Vector((math.cos(a), math.sin(a), 0))
        r = radius[i] + out
        centre = Vector((0, cy, z))
        rows.append([bm.verts.new(centre + d * (r + dr) + Vector((0, 0, dz))) for dr, dz in ((0, -half_w), (0, half_w), (-thick, half_w), (-thick, -half_w))])
    for i in range(n):
        a, b = rows[i], rows[(i + 1) % n]
        for k in range(4):
            bm.faces.new((a[k], b[k], b[(k + 1) % 4], a[(k + 1) % 4]))
    # Knot at the front (-Y) and two ends.
    front = Vector((0, cy - (radius[n // 4] + out) - 0.012, z))
    bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(front) @ Matrix.Diagonal((0.055, 0.03, 0.05, 1)))
    for side in (-1, 1):
        top = front + Vector((0.012 * side, -0.004, -0.018))
        tail = Matrix.Translation(top + Vector((0.03 * side, -0.004, -0.11))) @ Matrix.Rotation(0.18 * side, 4, "Y") @ Matrix.Diagonal((0.045, 0.006, 0.22, 1))
        bmesh.ops.create_cube(bm, size=1.0, matrix=tail)
    me = bpy.data.meshes.new("belt")
    bm.to_mesh(me)
    bm.free()
    belt = bpy.data.objects.new("belt", me)
    bpy.context.scene.collection.objects.link(belt)
    me.materials.append(bpy.data.materials.new("MI_Cloth_accent"))
    for name, w in (("pelvis", 0.5), ("spine_01", 0.5)):
        g = belt.vertex_groups.new(name=name)
        g.add(range(len(me.vertices)), w, "REPLACE")
    # UVs so the weave tiles along the band.
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv = (math.atan2(co.y - cy, co.x) / (2 * math.pi) * 6.0, co.z * 6.0)
    return belt


def hide_covered_skin(basemesh, lm):
    """Deletes body faces well inside the garments: nothing to see there, and no skin
    poking through the cloth when a joint bends."""
    bm = bmesh.new()
    bm.from_mesh(basemesh.data)
    doomed = [f for f in bm.faces if in_jacket(lm, basemesh.matrix_world @ f.calc_center_median(), margin=0.06)
              or in_trousers(lm, basemesh.matrix_world @ f.calc_center_median(), margin=0.06)]
    bmesh.ops.delete(bm, geom=doomed, context="FACES")
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bm.to_mesh(basemesh.data)
    bm.free()
    log("covered skin removed:", len(doomed), "faces")

# ---- 5. materials and export ----

def principled(name, base_tex=None, normal_tex=None, roughness=0.5, alpha=False, specular=0.5):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = roughness
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = specular
    if base_tex:
        img = nt.nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(base_tex)
        nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha:
            nt.links.new(img.outputs["Alpha"], bsdf.inputs["Alpha"])
            mat.surface_render_method = "DITHERED"
    if normal_tex:
        nimg = nt.nodes.new("ShaderNodeTexImage")
        nimg.image = bpy.data.images.load(normal_tex)
        nimg.image.colorspace_settings.name = "Non-Color"
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(nimg.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def texture(folder, pattern_end):
    for f in sorted(os.listdir(folder)):
        if f.endswith(pattern_end):
            return os.path.join(folder, f)
    return None


def assign(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)


def dress_materials(spec, basemesh, pieces, out_tex):
    os.makedirs(out_tex, exist_ok=True)

    def keep(path, name):
        if not path:
            return None
        dst = os.path.join(out_tex, name + os.path.splitext(path)[1])
        shutil.copyfile(path, dst)
        return dst
    skin_dir = user_data("skins", spec["skin"])
    assign(basemesh, principled("MI_Superhero_MH_Skin", keep(texture(skin_dir, "_diffuse.png"), "skin"), roughness=0.55, specular=0.35))
    assign(pieces["eyes"][0], principled("MI_Eyes_MH", keep(user_data("eyes", "materials", spec["eyes"] + "_eye.png"), "eyes"), roughness=0.15))
    for kind, mat_name in [("eyebrows", "MI_Hair_Brows"), ("eyelashes", "MI_Hair_Lashes")]:
        folder = user_data(kind, spec[kind])
        assign(pieces[kind][0], principled(mat_name, keep(texture(folder, ".png"), kind), roughness=0.6, alpha=True))
    hair_dir = user_data("hair", spec["hair"])
    assign(pieces["hair"][0], principled("MI_Hair_MH", keep(texture(hair_dir, "_diffuse.png"), "hair"), keep(texture(hair_dir, "_normal.png"), "hair_normal"), roughness=0.75, alpha=True))
    for kind, mat_name in [("teeth", "Teeth"), ("tongue", "Tongue")]:
        folder = user_data(kind, spec[kind])
        assign(pieces[kind][0], principled(mat_name, keep(texture(folder, ".png"), kind), roughness=0.3))


def finish_meshes(basemesh):
    # Helper geometry off, one subdivision for the body (shape keys kept).
    sub = basemesh.modifiers.new("Subdivide", "SUBSURF")
    sub.levels = 1
    sub.render_levels = 1
    ExportService.bake_modifiers_remove_helpers(basemesh, bake_masks=True, bake_subdiv=True, remove_helpers=True)
    # A second UV set for the game's tiling skin pore detail.
    if len(basemesh.data.uv_layers) == 1:
        basemesh.data.uv_layers.new(name="UVMap_detail")
    log("body", len(basemesh.data.polygons), "faces after subdivision")


def export(spec, out_dir):
    path = os.path.join(out_dir, spec["id"] + ".gltf")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              export_yup=True, export_skins=True, export_morph=True, export_morph_normal=True,
                              export_animations=False, export_apply=False, export_materials="EXPORT",
                              export_image_format="AUTO")
    log("exported", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    spec = json.load(open(argv[0]))
    blend_out = argv[argv.index("--blend") + 1] if "--blend" in argv else None
    out_dir = os.path.join(REPO, "assets/characters/mh", spec["id"])
    os.makedirs(out_dir, exist_ok=True)
    clear_scene()
    basemesh, rig, pieces = make_human(spec)
    game_arm, game = game_bone_dirs()
    pose_to_game(rig, game)
    bake_face_shapes(basemesh, pieces, spec.get("expression_race", "caucasian"))
    bake_gaze_shapes(pieces["eyes"][0])
    objects = [basemesh] + [p[0] for p in pieces.values()]
    scale_to_game(objects, rig, game)
    outfit, lm = make_outfit(basemesh, rig, spec)
    finish_meshes(basemesh)
    hide_covered_skin(basemesh, lm)
    build_game_skeleton(game_arm, rig, objects + outfit)
    import tempfile
    dress_materials(spec, basemesh, pieces, tempfile.mkdtemp(prefix="ringside_tex_"))
    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=blend_out)
    export(spec, out_dir)
    # The mirror-match skin: another MakeHuman skin on the same UV layout.
    if spec.get("alt_skin"):
        alt = texture(user_data("skins", spec["alt_skin"]), "_diffuse.png")
        shutil.copyfile(alt, os.path.join(out_dir, "textures", "skin_alt.png"))
        log("alt skin", spec["alt_skin"])


main()
