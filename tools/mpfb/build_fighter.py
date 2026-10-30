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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import outfits  # noqa: E402  (tools/mpfb/outfits.py)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GAME_SKELETONS = {
    "male": os.path.join(REPO, "assets/characters/base/Superhero_Male_FullBody.gltf"),
    "female": os.path.join(REPO, "assets/characters/base/Superhero_Female_FullBody.gltf"),
}
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

def game_bone_dirs(body):
    """Imports the game skeleton for this body ("male" or "female") and returns
    {bone: (head, direction, length, matrix)} plus the armature."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=GAME_SKELETONS[body], bone_heuristic="BLENDER")
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


def greyscale_for_tint(path):
    """Hair, brow and lash textures in grey (mean about 0.8 where opaque), so the game's
    hair_color decides the colour, as it does for the other fighters."""
    import numpy as np
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(-1, 4)
    lum = px[:, 0] * 0.2126 + px[:, 1] * 0.7152 + px[:, 2] * 0.0722
    opaque = px[:, 3] > 0.5
    mean = float(lum[opaque].mean()) if opaque.any() else 0.5
    lum = np.clip(lum * (0.8 / max(mean, 0.05)), 0.0, 1.0)
    px[:, 0] = px[:, 1] = px[:, 2] = lum
    img.pixels[:] = px.ravel()
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    return path


def skin_texture(name):
    """The skin's diffuse texture, as its .mhmat names it (file names vary: _diffuse3.png...)."""
    folder = user_data("skins", name)
    for line in open(os.path.join(folder, name + ".mhmat")):
        if line.startswith("diffuseTexture"):
            return os.path.join(folder, line.split(None, 1)[1].strip())
    raise FileNotFoundError(f"no diffuseTexture in {name}.mhmat")


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
    assign(basemesh, principled("MI_Superhero_MH_Skin", keep(skin_texture(spec["skin"]), "skin"), roughness=0.55, specular=0.35))
    assign(pieces["eyes"][0], principled("MI_Eyes_MH", keep(user_data("eyes", "materials", spec["eyes"] + "_eye.png"), "eyes"), roughness=0.15))
    for kind, mat_name in [("eyebrows", "MI_Hair_Brows"), ("eyelashes", "MI_Hair_Lashes")]:
        folder = user_data(kind, spec[kind])
        assign(pieces[kind][0], principled(mat_name, greyscale_for_tint(keep(texture(folder, ".png"), kind)), roughness=0.6, alpha=True))
    hair_dir = user_data("hair", spec["hair"])
    assign(pieces["hair"][0], principled("MI_Hair_MH", greyscale_for_tint(keep(texture(hair_dir, "_diffuse.png"), "hair")), keep(texture(hair_dir, "_normal.png"), "hair_normal"), roughness=0.75, alpha=True))
    beard = bpy.data.materials.get("MI_Hair_Beard")
    if beard:
        beard.use_nodes = True
        bsdf = beard.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = (0.8, 0.8, 0.8, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.92
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
                              export_image_format="AUTO", export_vertex_color="ACTIVE")
    log("exported", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    spec = json.load(open(argv[0]))
    blend_out = argv[argv.index("--blend") + 1] if "--blend" in argv else None
    out_dir = os.path.join(REPO, "assets/characters/mh", spec["id"])
    os.makedirs(out_dir, exist_ok=True)
    clear_scene()
    basemesh, rig, pieces = make_human(spec)
    game_arm, game = game_bone_dirs(spec.get("body", "male"))
    pose_to_game(rig, game)
    bake_face_shapes(basemesh, pieces, spec.get("expression_race", "caucasian"))
    bake_gaze_shapes(pieces["eyes"][0])
    objects = [basemesh] + [p[0] for p in pieces.values()]
    scale_to_game(objects, rig, game)
    outfit, _, outfit_spec = outfits.make_outfit(spec["id"], basemesh, rig, log)
    finish_meshes(basemesh)
    outfits.hide_covered_skin(basemesh, outfit_spec, log)
    build_game_skeleton(game_arm, rig, objects + outfit)
    import tempfile
    dress_materials(spec, basemesh, pieces, tempfile.mkdtemp(prefix="ringside_tex_"))
    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=blend_out)
    export(spec, out_dir)
    # The mirror-match skin: another MakeHuman skin on the same UV layout.
    if spec.get("alt_skin"):
        alt = skin_texture(spec["alt_skin"])
        shutil.copyfile(alt, os.path.join(out_dir, "textures", "skin_alt.png"))
        log("alt skin", spec["alt_skin"])


if __name__ == "__main__" and not getattr(sys, "_ringside_import", False):
    main()
