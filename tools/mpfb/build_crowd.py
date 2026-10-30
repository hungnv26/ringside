"""Builds the arena crowd: MakeHuman spectators baked for instanced, animated drawing.

    Blender -b --python tools/mpfb/build_crowd.py -- [id ...]

For each spectator in tools/mpfb/crowd.json (docs/graphics-plan.md, phase 3):

1. The MakeHuman body, hair, eyes and clothes (MakeHuman's CC0 casual and work suits,
   shoes, a fedora), rigged to the game skeleton the way build_fighter.py rigs fighters.
2. Everything joined into one mesh, its look baked into one 1024 px texture, decimated to
   about TARGET_TRIANGLES.
3. Its animations baked into vertex-animation textures (VAT): a position and a normal per
   vertex per frame, at FPS frames a second, for each clip: seated idle and talking (from
   the Universal Animation Library), and seated cheering and clapping (posed here, on top of
   the seated idle). Each vertex's column in the textures is stored in its second UV set.

Output: assets/crowd/<id>.glb (the mesh, in its rest pose; the atlas is <id>_atlas.png and
<id>_atlas_alt.png), the same again as <id>_lod.* at LOD_TRIANGLES for the back rows,
<id>_pos.vat and <id>_nrm.vat (the VAT, raw RGBA half floats, row 0 first; then run
tools/crowd_vat_import.gd to make the <id>_pos.res / <id>_nrm.res textures), and crowd.json
(per spectator: vertex count, rows, clips as [first row, rows]). scripts/stages/crowd.gd
draws them with assets/crowd/crowd_vat.gdshader.
"""
import json
import numpy
import math
import os
import sys

import bpy

sys._ringside_import = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_fighter as bf  # noqa: E402
import outfits  # noqa: E402  (tools/mpfb/outfits.py: the students' gi and hakama)

from mathutils import Vector  # noqa: E402
from bl_ext.blender_org.mpfb.services.humanservice import HumanService  # noqa: E402
from bl_ext.blender_org.mpfb.services.targetservice import TargetService  # noqa: E402
from bl_ext.blender_org.mpfb.services.exportservice import ExportService  # noqa: E402

OUT = os.path.join(bf.REPO, "assets", "crowd")
SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crowd.json")
UAL = [os.path.join(bf.REPO, "assets/animations/UAL1_Standard.glb"), os.path.join(bf.REPO, "assets/animations/UAL2_Standard.glb")]
TARGET_TRIANGLES = 2400
# The level of detail for the rows further back (Crowd.NEAR_ROWS): its own mesh and VAT.
LOD_TRIANGLES = 900
ATLAS = 1024
FPS = 15
CHEER_SECONDS = 1.2
CLAP_SECONDS = 0.8
# Seated-on-the-floor (seiza) students: every clip is posed here, none comes from the library.
SEIZA_IDLE_SECONDS = 3.2
SEIZA_TALK_SECONDS = 2.4
WEAVE = os.path.join(bf.REPO, "assets/characters/outfits/textures/detail/cotton_jersey_weave_2k.jpg")


def log(*a):
    print("CROWD", *a, flush=True)


def build_person(spec):
    bf.clear_scene()
    macros = dict(spec["macros"])
    race = macros.pop("race")
    detail = TargetService.get_default_macro_info_dict()
    detail.update(macros)
    detail["race"] = race
    basemesh = HumanService.create_human(macro_detail_dict=detail)
    TargetService.bake_targets(basemesh)
    rig = HumanService.add_builtin_rig(basemesh, "game_engine")
    pieces = []
    for kind, name in [("eyes", "low-poly"), ("hair", spec["hair"])] + [("clothes", c) for c in spec["clothes"]]:
        obj = HumanService.add_mhclo_asset(bf.asset_mhclo(kind, name), basemesh, asset_type=kind.capitalize(), subdiv_levels=0)
        pieces.append(obj)
    bf.assign(basemesh, bf.principled("skin", bf.skin_texture(spec["skin"]), roughness=0.6))
    game_arm, game = bf.game_bone_dirs(spec["body"])
    bf.pose_to_game(rig, game)
    objects = [basemesh] + pieces
    bf.scale_to_game(objects, rig, game)
    outfit, outfit_spec = [], None
    if spec.get("outfit"):
        outfit, _, outfit_spec = outfits.make_outfit(spec["outfit"], basemesh, rig, log)
        dress_outfit(spec["colors"])
    # Helpers and the skin the clothes' delete groups hide.
    ExportService.bake_modifiers_remove_helpers(basemesh, bake_masks=True, bake_subdiv=False, remove_helpers=True)
    for o in objects:
        for m in list(o.modifiers):
            if m.type == "MASK":
                bf.set_active(o)
                bpy.ops.object.modifier_apply(modifier=m.name)
    if outfit_spec:
        outfits.hide_covered_skin(basemesh, outfit_spec, log)
        objects += outfit
    bf.build_game_skeleton(game_arm, rig, objects)
    for o in objects:
        if o.data.uv_layers:
            o.data.uv_layers[0].name = "UVMap"
    bpy.ops.object.select_all(action="DESELECT")
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = basemesh
    bpy.ops.object.join()
    person = basemesh
    person.name = spec["id"]
    log(spec["id"], "joined:", len(person.data.polygons), "faces,", len(person.data.materials), "materials")
    return person, game_arm


def dress_outfit(colors):
    """Gives the generated outfit's slots (MI_Cloth_main/trim/accent/extra) their colours for
    the atlas bake: the colour times the hem shading in the vertex colour ("Col") times a
    cotton weave, box-projected."""
    for slot in outfits.SLOT_NAMES:
        mat = bpy.data.materials.get(f"MI_Cloth_{slot}")
        if mat is None:
            continue
        set_cloth_colour(mat, colors.get(slot, [0.5, 0.5, 0.5]))


def set_cloth_colour(mat, rgb):
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    tint = nodes.get("Tint") or nodes.new("ShaderNodeRGB")
    tint.name = "Tint"
    tint.outputs[0].default_value = (*rgb, 1.0)
    if nodes.get("Hem") is None:
        hem = nodes.new("ShaderNodeAttribute")
        hem.name = "Hem"
        hem.attribute_name = "Col"
        coords = nodes.new("ShaderNodeTexCoord")
        weave = nodes.new("ShaderNodeTexImage")
        weave.image = bpy.data.images.load(WEAVE, check_existing=True)
        weave.projection = "BOX"
        weave.projection_blend = 0.3
        mapping = nodes.new("ShaderNodeMapping")
        mapping.inputs["Scale"].default_value = (7.0, 7.0, 7.0)
        links.new(coords.outputs["Object"], mapping.inputs["Vector"])
        links.new(mapping.outputs["Vector"], weave.inputs["Vector"])
        weave_mix = nodes.new("ShaderNodeMix")
        weave_mix.data_type = "RGBA"
        weave_mix.inputs["Factor"].default_value = 0.35
        weave_mix.inputs["A"].default_value = (1, 1, 1, 1)
        links.new(weave.outputs["Color"], weave_mix.inputs["B"])
        a = nodes.new("ShaderNodeMix")
        a.data_type = "RGBA"
        a.blend_type = "MULTIPLY"
        a.inputs["Factor"].default_value = 1.0
        a.name = "TintTimesHem"
        links.new(tint.outputs[0], a.inputs["A"])
        links.new(hem.outputs["Color"], a.inputs["B"])
        b = nodes.new("ShaderNodeMix")
        b.data_type = "RGBA"
        b.blend_type = "MULTIPLY"
        b.inputs["Factor"].default_value = 1.0
        links.new(a.outputs["Result"], b.inputs["A"])
        links.new(weave_mix.outputs["Result"], b.inputs["B"])
        links.new(b.outputs["Result"], bsdf.inputs["Base Color"])


def bake_atlas(person, path, spec):
    """Bakes the joined person's look into one ATLAS texture at `path`, and a second
    colourway at <path>_alt: the clothes shifted by spec["alt"] = [hue shift, saturation,
    value], so the stands don't fill with the same shirt (or, for a generated outfit,
    spec["alt_colors"]: new colours for some of its slots, such as another belt)."""
    me = person.data
    atlas_uv = me.uv_layers.new(name="atlas")
    me.uv_layers["UVMap"].active_render = True
    me.uv_layers.active = atlas_uv
    bf.set_active(person)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 1
    alt_path = path.replace(".png", "_alt.png")
    for out, shift in ((path, None), (alt_path, spec.get("alt", [0.5, 1.0, 1.0]))):
        img = bpy.data.images.new("atlas_" + person.name, ATLAS, ATLAS, alpha=False)
        for mat in me.materials:
            if mat is None:
                continue
            mat.use_nodes = True
            node = mat.node_tree.nodes.new("ShaderNodeTexImage")
            node.image = img
            mat.node_tree.nodes.active = node
            if shift is not None and spec.get("alt_colors") and mat.name.startswith("MI_Cloth_"):
                slot = mat.name[len("MI_Cloth_"):].split(".")[0]
                if slot in spec["alt_colors"]:
                    set_cloth_colour(mat, spec["alt_colors"][slot])
            elif shift is not None and _is_clothing(mat, spec):
                _shift_colour(mat, shift)
        bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=4, use_clear=True)
        img.filepath_raw = out
        img.file_format = "PNG"
        img.save()
    # One plain material on the atlas, the atlas becomes the only UV set.
    me.uv_layers.remove(me.uv_layers["UVMap"])
    me.uv_layers["atlas"].name = "UVMap"
    me.materials.clear()
    me.materials.append(bf.principled("MI_Crowd_" + person.name, path, roughness=0.75))
    for poly in me.polygons:
        poly.material_index = 0


def _is_clothing(mat, spec):
    name = mat.name.lower()
    return any(item.lower() in name for item in spec["clothes"] if not item.startswith("shoes"))


def _shift_colour(mat, shift):
    """Puts a hue/saturation/value node in front of the material's base colour."""
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        log(mat.name, "no principled BSDF, colour not shifted")
        return
    base = bsdf.inputs["Base Color"]
    hsv = nodes.new("ShaderNodeHueSaturation")
    hsv.inputs["Hue"].default_value = (0.5 + shift[0]) % 1.0
    hsv.inputs["Saturation"].default_value = shift[1]
    hsv.inputs["Value"].default_value = shift[2]
    if base.is_linked:
        source = base.links[0].from_socket
        links.remove(base.links[0])
        links.new(source, hsv.inputs["Color"])
    else:
        hsv.inputs["Color"].default_value = base.default_value
    links.new(hsv.outputs["Color"], base)
    log(mat.name, "colour shifted", shift)


def decimate(person, target=TARGET_TRIANGLES):
    tris = sum(len(p.vertices) - 2 for p in person.data.polygons)
    m = person.modifiers.new("Decimate", "DECIMATE")
    m.ratio = min(1.0, target / max(tris, 1))
    m.use_collapse_triangulate = True
    bf.set_active(person)
    # The armature modifier must stay last (and unapplied): move the decimate to the top.
    while person.modifiers.find("Decimate") > 0:
        bpy.ops.object.modifier_move_up(modifier="Decimate")
    bpy.ops.object.modifier_apply(modifier="Decimate")
    log(person.name, "decimated", tris, "->", sum(len(p.vertices) - 2 for p in person.data.polygons), "triangles,", len(person.data.vertices), "vertices")


# ---- animations ----

def load_actions():
    before = set(bpy.data.objects)
    for path in UAL:
        bpy.ops.import_scene.gltf(filepath=path, bone_heuristic="BLENDER")
    for o in [o for o in bpy.data.objects if o not in before]:
        bpy.data.objects.remove(o, do_unlink=True)
    return {a.name.split("|")[-1].removesuffix("_Loop"): a for a in bpy.data.actions}


def use_action(arm, action):
    arm.animation_data_create()
    arm.animation_data.action = action
    if hasattr(arm.animation_data, "action_slot") and getattr(action, "slots", None):
        arm.animation_data.action_slot = action.slots[0]


def sample(person):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = person.evaluated_get(dg)
    me = ev.to_mesh()
    pos = [(v.co.x, v.co.z, -v.co.y) for v in me.vertices] # to the game's y-up frame
    nrm = [(v.normal.x, v.normal.z, -v.normal.y) for v in me.vertices]
    ev.to_mesh_clear()
    return pos, nrm


def clip_frames(arm, person, action, seconds=None, pose=None):
    """Samples `action` at FPS (or, with `pose`, the first frame of `action` with pose(t)
    layered on top for `seconds`) and returns [(positions, normals), ...]."""
    scene = bpy.context.scene
    use_action(arm, action)
    start, end = action.frame_range
    rows = []
    if pose is None:
        count = max(2, int((end - start) / scene.render.fps * FPS))
        for i in range(count):
            scene.frame_set(int(round(start + i * (end - start) / count)))
            rows.append(sample(person))
    else:
        count = int(seconds * FPS)
        for i in range(count):
            scene.frame_set(int(start + (i % 8)))  # a little of the idle's breathing
            pose(arm, i / count)
            bpy.context.view_layer.update()
            rows.append(sample(person))
    return rows


def _aim(arm, bone, direction):
    bf.align(arm, bone, Vector(direction).normalized())


def cheer_pose(arm, t):
    """Both fists up, pumping twice a loop; the body leans back a little."""
    pump = math.sin(t * 2 * math.pi * 2)
    for side, s in (("l", 1), ("r", -1)):
        _aim(arm, f"upperarm_{side}", (s * 0.45, -0.12, 0.88 + 0.08 * pump))
        _aim(arm, f"lowerarm_{side}", (s * 0.1, -0.35 - 0.25 * (0.5 + 0.5 * pump), 0.9))
        _aim(arm, f"hand_{side}", (s * 0.05, -0.3, 1.0))


def clap_pose(arm, t):
    """Hands meeting in front of the chest twice a loop."""
    meet = 0.5 + 0.5 * math.cos(t * 2 * math.pi * 2) # 1 = hands together
    for side, s in (("l", 1), ("r", -1)):
        _aim(arm, f"upperarm_{side}", (s * 0.35, -0.75, -0.45))
        _aim(arm, f"lowerarm_{side}", (-s * (0.25 + 0.35 * meet), -0.85, 0.25))
        _aim(arm, f"hand_{side}", (-s * (0.4 + 0.4 * meet), -0.6, 0.2))


def seiza_pose(arm, breath=0.0, lean=0.0):
    """Kneeling, sitting back on the heels: thighs sloping down to the knees on the floor,
    shins flat behind them, feet flat with the toes back, back straight, hands on the
    thighs. `breath` (0-1) lifts the chest a little; `lean` bows the upper body forward."""
    for b in arm.pose.bones:
        b.matrix_basis.identity()
    bpy.context.view_layer.update()
    _aim(arm, "spine_01", (0.0, 0.04 - 0.3 * lean, 1.0))
    _aim(arm, "spine_02", (0.0, 0.02 - 0.4 * lean - 0.02 * breath, 1.0))
    _aim(arm, "spine_03", (0.0, -0.4 * lean - 0.03 * breath, 1.0))
    _aim(arm, "neck_01", (0.0, -0.12 - 0.3 * lean, 1.0))
    _aim(arm, "Head", (0.0, -0.05 - 0.2 * lean, 1.0))
    for side, s in (("l", 1), ("r", -1)):
        _aim(arm, f"thigh_{side}", (s * 0.13, -0.98, -0.16))
        _aim(arm, f"calf_{side}", (s * 0.02, 0.995, -0.08))
        _aim(arm, f"foot_{side}", (s * 0.02, 0.96, -0.2))
        _aim(arm, f"ball_{side}", (0.0, 1.0, 0.0))
        _aim(arm, f"upperarm_{side}", (s * 0.07, -0.2 - 0.3 * lean, -0.97))
        _aim(arm, f"lowerarm_{side}", (-s * 0.08, -0.97, -0.22))
        _aim(arm, f"hand_{side}", (-s * 0.03, -0.9, -0.42))


def seiza_frames(arm, person, seconds, overlay):
    """Samples seiza_pose with `overlay(arm, t)` on top for `seconds` at FPS."""
    rows = []
    count = int(seconds * FPS)
    for i in range(count):
        t = i / count
        overlay(arm, t)
        bpy.context.view_layer.update()
        rows.append(sample(person))
    return rows


def seiza_idle(arm, t):
    seiza_pose(arm, breath=0.5 - 0.5 * math.cos(t * 2 * math.pi * 1.0))


def seiza_talk(arm, t):
    """Leaning toward a neighbour, head turned, one hand moving as they speak."""
    seiza_pose(arm, breath=0.3, lean=0.08)
    _aim(arm, "Head", (0.35, -0.2, 0.92))
    wave = math.sin(t * 2 * math.pi * 2)
    _aim(arm, "upperarm_r", (-0.25, -0.55, -0.8))
    _aim(arm, "lowerarm_r", (0.15, -0.8 - 0.1 * wave, 0.35 + 0.2 * wave))
    _aim(arm, "hand_r", (0.25, -0.75, 0.6))


def seiza_cheer(arm, t):
    """A kiai: the right fist punched up, twice a loop; the left hand stays on the thigh."""
    seiza_pose(arm, breath=0.8)
    pump = math.sin(t * 2 * math.pi * 2)
    _aim(arm, "upperarm_r", (-0.3, -0.25, 0.92 + 0.05 * pump))
    _aim(arm, "lowerarm_r", (-0.05, -0.3 - 0.3 * (0.5 + 0.5 * pump), 0.95))
    _aim(arm, "hand_r", (0.0, -0.25, 1.0))


def seiza_clap(arm, t):
    seiza_pose(arm, breath=0.6)
    clap_pose(arm, t)


def seiza_clips(person, arm):
    clips = {
        "idle": seiza_frames(arm, person, SEIZA_IDLE_SECONDS, seiza_idle),
        "talk": seiza_frames(arm, person, SEIZA_TALK_SECONDS, seiza_talk),
        "cheer": seiza_frames(arm, person, CHEER_SECONDS, seiza_cheer),
        "clap": seiza_frames(arm, person, CLAP_SECONDS, seiza_clap),
    }
    # The pose keeps the standing hips; drop everything so the shins rest on the floor.
    floor = min(p[1] for p in clips["idle"][0][0])
    for frames in clips.values():
        for k, (pos, nrm) in enumerate(frames):
            frames[k] = ([(x, y - floor, z) for x, y, z in pos], nrm)
    return clips


def bake_vat(person, arm, actions, stem, seiza=False):
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    if seiza:
        if arm.animation_data:
            arm.animation_data.action = None
        clips = seiza_clips(person, arm)
    else:
        idle = actions["Sitting_Idle"]
        clips = {
            "idle": clip_frames(arm, person, idle),
            "talk": clip_frames(arm, person, actions["Sitting_Talking"]),
            "cheer": clip_frames(arm, person, idle, CHEER_SECONDS, cheer_pose),
            "clap": clip_frames(arm, person, idle, CLAP_SECONDS, clap_pose),
        }
    bpy.ops.object.mode_set(mode="OBJECT")
    width = len(person.data.vertices)
    rows = sum(len(r) for r in clips.values())
    table, row = {}, 0
    pos_px = numpy.zeros((rows, width, 4), dtype=numpy.float16)
    nrm_px = numpy.zeros((rows, width, 4), dtype=numpy.float16)
    for name, frames in clips.items():
        table[name] = [row, len(frames)]
        for pos, nrm in frames:
            pos_px[row, :, :3] = pos
            nrm_px[row, :, :3] = nrm
            pos_px[row, :, 3] = 1.0
            nrm_px[row, :, 3] = 1.0
            row += 1
    # Raw little-endian RGBA half floats, row 0 first (Godot's EXR reader garbles Blender's
    # files); tools/crowd_vat_import.gd turns them into <id>_pos.res / <id>_nrm.res.
    for suffix, px in (("pos", pos_px), ("nrm", nrm_px)):
        with open(os.path.join(OUT, f"{stem}_{suffix}.vat"), "wb") as f:
            f.write(px.astype("<f2").tobytes())
    log(stem, "VAT", width, "x", rows, {k: v[1] for k, v in table.items()})
    return {"vertices": width, "rows": rows, "fps": FPS, "clips": table, "kind": "student" if seiza else "spectator"}


def vat_uv(person):
    """Each vertex's VAT column in the second UV set (glTF splits vertices at seams, so the
    vertex order in the game can't be trusted)."""
    me = person.data
    uv = me.uv_layers.get("VAT") or me.uv_layers.new(name="VAT")
    # Two 6-bit halves (column % 64, column // 64): the game stores UV2 at half precision,
    # which can't tell neighbouring columns apart as one fraction above about 1000.
    for loop in me.loops:
        i = loop.vertex_index
        uv.data[loop.index].uv = (((i % 64) + 0.5) / 64.0, ((i // 64) + 0.5) / 64.0)


def export_mesh(person, path):
    bpy.ops.object.select_all(action="DESELECT")
    person.select_set(True)
    bpy.context.view_layer.objects.active = person
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_skins=False,
                              export_animations=False, export_morph=False, export_apply=False, export_yup=True,
                              export_materials="NONE",  # the game draws it with crowd_vat.gdshader
                              export_vertex_color="NONE")  # the hem shading is in the atlas; COLOR is the seat tint


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    specs = json.load(open(SPEC))["spectators"]
    meta_path = os.path.join(OUT, "crowd.json")
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    for spec in specs:
        if argv and spec["id"] not in argv:
            continue
        person, arm = build_person(spec)
        bake_atlas(person, os.path.join(OUT, spec["id"] + "_atlas.png"), spec)
        actions = load_actions()
        for target, stem in ((TARGET_TRIANGLES, spec["id"]), (LOD_TRIANGLES, spec["id"] + "_lod")):
            decimate(person, target)
            vat_uv(person)
            info = bake_vat(person, arm, actions, stem, spec.get("pose") == "seiza")
            if stem == spec["id"]:
                meta[spec["id"]] = info
            else:
                meta[spec["id"]]["lod"] = {"vertices": info["vertices"]}
            # The mesh in its rest pose (no action on the skeleton).
            if arm.animation_data:
                arm.animation_data.action = None
            bpy.context.scene.frame_set(0)
            for b in arm.pose.bones:
                b.matrix_basis.identity()
            export_mesh(person, os.path.join(OUT, stem + ".glb"))
        json.dump(meta, open(meta_path, "w"), indent=1)
        log(spec["id"], "done")


main()
