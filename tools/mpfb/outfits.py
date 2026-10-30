"""Fighter outfits for the MakeHuman builder (tools/mpfb/build_fighter.py).

A port of tools/build_outfits.gd's garment language to Blender, so every fighter keeps the
outfit it had: a garment is the part of the body surface inside a region, a signed-distance
function of the T-pose position (positive inside) built from the skeleton's landmarks. The
surface is cut exactly along the region's zero line (clean hems, necklines and sleeve ends),
pushed out along the normals by the garment's thickness, given folds where the cloth is
loose, its hems turned inward for thickness and darkened a little toward each edge. Trims are
cut the same way into their own colour slot. Every vertex keeps the body's bone weights, so
the cloth moves exactly with the skin under it, and skin well inside a garment is deleted.

Regions use the game's frame, as in build_outfits.gd: y up, z toward the face. Blender's is
z up with the face toward -y; `G` converts.
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

MAIN, TRIM, ACCENT, EXTRA = 0, 1, 2, 3
SLOT_NAMES = ["main", "trim", "accent", "extra"]
NECK_RADIUS = 0.072
ARM_LIMIT = 0.35
HIDE_INSET = 0.015
HEM_SHADE = 0.8
HEM_SHADE_DEPTH = 0.035


def G(v):
    """Blender (z up, face -y) to the game's frame (y up, face +z)."""
    return Vector((v.x, v.z, -v.y))


# ---- region helpers (ports of build_outfits.gd) ----

def top(p, L, y0, sleeve_end):
    band = min(p.y - y0, (L["neck"] + 0.03) - p.y, sleeve_end - abs(p.x))
    return min(band, -neck_hole(p, L))


def sleeveless(p, L, y0, armhole):
    side = max(armhole - abs(p.x), (L["chest"] - 0.06) - p.y)
    band = min(p.y - y0, (L["neck"] + 0.03) - p.y, side, ARM_LIMIT - abs(p.x))
    return min(band, -neck_hole(p, L))


def legs(p, y0, y1):
    return min(p.y - y0, y1 - p.y, ARM_LIMIT - abs(p.x))


def neck_hole(p, L):
    r = L.get("neck_r", NECK_RADIUS)
    e = math.hypot(p.x / r, (p.z - L["neck_z"]) / (r * 0.95))
    return min(r * (1.0 - e), p.y - (L["neck"] - 0.035))


def v_cut(p, n, L, bottom, width):
    if p.z <= 0.0 or n.z < 0.15:
        return -1.0
    half = width * (p.y - bottom) / (L["neck"] - bottom)
    return min(half - abs(p.x), p.y - bottom)


def zip_line(p, n, half_width):
    if p.z <= 0.0 or n.z < 0.3:
        return -1.0
    return half_width - abs(p.x)


def scoop(p, L, depth, half_width):
    return min(p.y - (L["neck"] - depth), half_width - abs(p.x))


def wrists(p, L, from_wrist, past_wrist):
    """Hand wraps and gloves: from `from_wrist` up the forearm to `past_wrist` over the hand."""
    return min(p.y - (L["arm_y"] - 0.12), abs(p.x) - (L["wrist"] - from_wrist), (L["wrist"] + past_wrist) - abs(p.x))


# ---- the fighters' outfits ----
# A piece: slot, offset (metres, or func(n)), region func(p, n), optional trim func and
# trim_slot, hide (remove skin under it, default True), flat_soles, folds (amplitude of the
# fabric folds), flare (extra width at the ankle), sleeve (extra looseness of the sleeves).

def specs(fighter, L):
    if fighter == "jin":
        v_bottom = L["chest"]
        return {"pieces": [
            # Dobok: V-neck pullover to the hips, long sleeves, black V collar.
            dict(slot=MAIN, offset=0.02, folds=0.0045, sleeve=0.014, trim_slot=TRIM,
                 trim=lambda p, n: v_cut(p, n, L, v_bottom - 0.035, 0.08) + 0.03,
                 region=lambda p, n: min(top(p, L, L["hip"] - 0.05, L["wrist"] - 0.05), -v_cut(p, n, L, v_bottom, 0.08))),
            dict(slot=MAIN, offset=0.016, folds=0.006, flare=0.03, region=lambda p, n: legs(p, L["ankle"] + 0.05, L["waist"] - 0.02)),
            dict(slot=TRIM, offset=0.034, hide=False, region=lambda p, n: legs(p, L["hip"] + 0.04, L["hip"] + 0.085)),
        ], "belt_knot": dict(slot=TRIM, y=0.0625, offset=0.034)}
    if fighter == "kenji":
        return {"pieces": [
            # Gi jacket: past the hips, sleeves to mid-forearm, a deep V at the chest.
            dict(slot=MAIN, offset=0.024, folds=0.0045, sleeve=0.016,
                 region=lambda p, n: min(top(p, L, L["hip"] - 0.06, L["elbow"] + (L["wrist"] - L["elbow"]) * 0.45), -v_cut(p, n, L, L["chest"] - 0.07, 0.075))),
            dict(slot=MAIN, offset=0.018, folds=0.006, flare=0.03, region=lambda p, n: legs(p, L["ankle"] + 0.07, L["waist"] - 0.02)),
            dict(slot=TRIM, offset=0.038, hide=False, region=lambda p, n: legs(p, L["hip"] + 0.04, L["hip"] + 0.085)),
            # Red headband: snug on the forehead, standing off over the hair at the sides and back.
            dict(slot=ACCENT, offset=lambda n: 0.02 + (0.009 - 0.02) * max(0.0, min(1.0, n.z * 1.6 - 0.4)), hide=False, hem=False,
                 region=lambda p, n: min(p.y - (L["head_top"] - 0.078), (L["head_top"] - 0.05) - p.y, 0.15 - abs(p.x))),
        ], "belt_knot": dict(slot=TRIM, y=0.0625, offset=0.038)}
    if fighter == "rhea":
        return {"pieces": [
            # Sports crop top: under the bust to the shoulders, scooped neck, sleeveless.
            dict(slot=MAIN, offset=0.005, region=lambda p, n: min(sleeveless(p, L, L["chest"] - 0.11, L["shoulder"] * 0.95), -scoop(p, L, 0.10, 0.07))),
            # Fight shorts to mid-thigh, covering the waistband.
            dict(slot=TRIM, offset=0.006, folds=0.0015, region=lambda p, n: legs(p, L["knee"] + 0.2, L["waist"] + 0.03)),
            # Hand wraps over the wrists and palms.
            dict(slot=ACCENT, offset=0.004, hem=False, region=lambda p, n: wrists(p, L, 0.08, 0.07)),
        ]}
    if fighter == "valka":
        singlet = lambda p, n: min(sleeveless(p, L, L["knee"] + 0.24, L["shoulder"] * 0.95), -scoop(p, L, 0.11, 0.06))
        return {"pieces": [
            # Wrestling singlet: short legs, scooped neck, gold edging along every opening.
            dict(slot=MAIN, offset=0.006, trim_slot=TRIM, region=singlet, trim=lambda p, n: 0.014 - singlet(p, n)),
            # Knee pads and wrestling boots.
            dict(slot=ACCENT, offset=0.028, region=lambda p, n: legs(p, L["knee"] - 0.065, L["knee"] + 0.065)),
            dict(slot=ACCENT, offset=0.012, flat_soles=True, region=lambda p, n: legs(p, -1.0, L["ankle"] + 0.22)),
        ]}
    if fighter == "brutus":
        return {"pieces": [
            # Tank top, tucked into the pants.
            dict(slot=MAIN, offset=0.009, folds=0.002, region=lambda p, n: min(sleeveless(p, L, L["waist"] - 0.1, L["shoulder"] * 0.85), -scoop(p, L, 0.09, 0.07))),
            # Work pants over the boot tops.
            dict(slot=TRIM, offset=0.016, folds=0.004, region=lambda p, n: legs(p, L["ankle"] + 0.17, L["waist"])),
            dict(slot=ACCENT, offset=0.014, flat_soles=True, region=lambda p, n: legs(p, -1.0, L["ankle"] + 0.21)),
        ], "beard": True}
    if fighter == "mira":
        hem = L["waist"] - 0.07
        return {"pieces": [
            # Sleeveless zip-up to the waist, a contrast zip and a contrast band at the hem.
            dict(slot=MAIN, offset=0.014, folds=0.002, trim_slot=TRIM,
                 region=lambda p, n: sleeveless(p, L, hem, L["shoulder"] * 0.9),
                 trim=lambda p, n: max(zip_line(p, n, 0.007), (hem + 0.022) - p.y)),
            # Track pants with contrast stripes down the outside of each leg.
            dict(slot=ACCENT, offset=0.010, folds=0.004, flare=0.008, trim_slot=TRIM,
                 region=lambda p, n: legs(p, L["ankle"] + 0.06, L["waist"] + 0.005),
                 trim=lambda p, n: math.copysign(1.0, p.x) * n.x - 0.93),
            # Fingerless gloves: wrist to knuckles.
            dict(slot=ACCENT, offset=0.004, hem=False, region=lambda p, n: wrists(p, L, 0.06, 0.085)),
            # Leather sneakers over the ankle with a contrast sole.
            dict(slot=EXTRA, offset=0.018, flat_soles=True, trim_slot=TRIM,
                 region=lambda p, n: legs(p, -1.0, L["ankle"] + 0.07), trim=lambda p, n: 0.03 - p.y),
        ]}
    if fighter == "lian":
        hem = L["hip"] - 0.05
        sleeve = L["shoulder"] + (L["elbow"] - L["shoulder"]) * 0.55
        return {"pieces": [
            # Kung fu jacket: to the hips, short sleeves, the collar standing at the neck;
            # contrast trim on the collar, the front placket, the hem and the cuffs.
            dict(slot=MAIN, offset=0.015, folds=0.0035, sleeve=0.01, over_below_waist=0.014, trim_slot=TRIM,
                 region=lambda p, n: top(p, L, hem, sleeve),
                 trim=lambda p, n: max(zip_line(p, n, 0.009), p.y - (L["neck"] - 0.012), (hem + 0.02) - p.y, abs(p.x) - (sleeve - 0.02))),
            # Loose pants to the ankle.
            dict(slot=ACCENT, offset=0.017, folds=0.005, flare=0.02, region=lambda p, n: legs(p, L["ankle"] + 0.04, L["waist"] - 0.02)),
            # Cloth shoes with white soles.
            dict(slot=EXTRA, offset=0.01, flat_soles=True, trim_slot=TRIM,
                 region=lambda p, n: legs(p, -1.0, L["ankle"] + 0.03), trim=lambda p, n: 0.022 - p.y),
        ]}
    if fighter in ("student_gi", "student_hakama"):
        # Dojo students (tools/mpfb/build_crowd.py): a karate gi jacket past the hips with a
        # modest V (a training gi, closed higher than Kenji's) and sleeves to mid-forearm, and either gi trousers with a belt or a wide,
        # pleated hakama from the waist to the ankles over the jacket's skirt.
        jacket = dict(slot=MAIN, offset=0.024, folds=0.0045, sleeve=0.016,
                      region=lambda p, n: min(top(p, L, L["hip"] - 0.06, L["elbow"] + (L["wrist"] - L["elbow"]) * 0.45), -v_cut(p, n, L, L["chest"] + 0.03, 0.06)))
        if fighter == "student_gi":
            return {"pieces": [
                jacket,
                dict(slot=MAIN, offset=0.018, folds=0.006, flare=0.03, region=lambda p, n: legs(p, L["ankle"] + 0.07, L["waist"] - 0.02)),
                dict(slot=TRIM, offset=0.038, hide=False, region=lambda p, n: legs(p, L["hip"] + 0.04, L["hip"] + 0.085)),
            ], "belt_knot": dict(slot=TRIM, y=0.0625, offset=0.038)}
        return {"pieces": [
            jacket,
            dict(slot=ACCENT, offset=0.03, folds=0.008, flare=0.05, over_below_waist=0.016,
                 region=lambda p, n: legs(p, L["ankle"] + 0.01, L["waist"] + 0.03)),
        ]}
    raise KeyError(fighter)


# ---- building ----

def landmarks(rig, body):
    def head(name):
        return G(rig.matrix_world @ rig.data.bones[name].head_local)
    top_z = max((body.matrix_world @ v.co).z for v in body.data.vertices if is_body(body, v))
    L = {
        "hip": head("pelvis").y, "waist": head("spine_01").y, "chest": head("spine_03").y,
        "neck": head("neck_01").y, "neck_z": head("neck_01").z,
        "shoulder": head("upperarm_l").x, "elbow": head("lowerarm_l").x, "wrist": head("hand_l").x,
        "arm_y": head("upperarm_l").y, "knee": head("calf_l").y, "ankle": head("foot_l").y,
        "head_top": top_z,
    }
    # The neck hole is centred on the neck itself (MakeHuman's neck bone sits toward the
    # back of the neck) and a little wider than it.
    ring = [G(body.matrix_world @ v.co) for v in body.data.vertices if is_body(body, v) and abs((body.matrix_world @ v.co).z - (L["neck"] + 0.01)) < 0.012 and abs(v.co.x) < 0.1]
    if ring:
        cz = (max(q.z for q in ring) + min(q.z for q in ring)) / 2
        L["neck_z"] = cz
        L["neck_r"] = max(math.hypot(q.x, q.z - cz) for q in ring) + 0.018
    return L


def is_body(obj, v):
    g = obj.vertex_groups.get("body")
    return g is not None and any(e.group == g.index for e in v.groups)


def copy_body(basemesh, name, keep, keep_shapes=False):
    """A new object with the body faces whose game-frame centre/normal pass keep(p, n)
    (cheap pre-selection), with the body's vertex groups and, optionally, its shape keys."""
    me = basemesh.data.copy()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for g in basemesh.vertex_groups:
        obj.vertex_groups.new(name=g.name)
    if me.shape_keys and not keep_shapes:
        for o in bpy.context.view_layer.objects:
            o.select_set(False)
        bpy.context.view_layer.objects.active = obj
        obj.shape_key_clear()
    body_group = basemesh.vertex_groups["body"].index
    bm = bmesh.new()
    bm.from_mesh(me)
    deform = bm.verts.layers.deform.active
    bm.normal_update()
    doomed = [f for f in bm.faces if not all(body_group in v[deform] for v in f.verts) or not keep(G(f.calc_center_median()), G(f.normal))]
    bmesh.ops.delete(bm, geom=doomed, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(me)
    bm.free()
    obj.matrix_world = basemesh.matrix_world.copy()
    return obj


def subdivide(obj):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    bpy.context.view_layer.objects.active = obj
    m = obj.modifiers.new("Sub", "SUBSURF")
    m.levels = 1
    bpy.ops.object.modifier_apply(modifier=m.name)


def cut(bm, field):
    """Splits every edge crossing field's zero line at the crossing and joins the new
    vertices across each face, so faces lie wholly on one side. Returns {vert: value}."""
    bm.normal_update()
    vals = {v: field(G(v.co), G(v.normal)) for v in bm.verts}
    eps = 1e-7
    zero = {v for v, f in vals.items() if abs(f) < eps}
    crossing = [e for e in bm.edges if (vals[e.verts[0]] > eps and vals[e.verts[1]] < -eps) or (vals[e.verts[0]] < -eps and vals[e.verts[1]] > eps)]
    for e in crossing:
        a, b = e.verts
        fa, fb = vals[a], vals[b]
        t = fa / (fa - fb)
        _, nv = bmesh.utils.edge_split(e, a, t)
        vals[nv] = 0.0
        zero.add(nv)
    for f in list(bm.faces):
        zs = [v for v in f.verts if v in zero]
        if len(zs) < 2:
            continue
        sides = {(vals[v] > 0) for v in f.verts if v not in zero}
        if len(sides) < 2:
            continue
        for i in range(0, len(zs) - 1, 2):
            pair = [zs[i], zs[i + 1]]
            if bm.edges.get(pair) is None:
                try:
                    bmesh.ops.connect_verts(bm, verts=pair)
                except Exception:
                    pass
    return vals


def face_value(f, vals):
    return sum(vals.get(v, 0.0) for v in f.verts) / len(f.verts)


def fold(c, along_x, seed):
    q = Vector((c.x * (3.0 if along_x else 24.0), c.y * 24.0, c.z * (24.0 if along_x else 3.0))) + Vector((seed, seed * 0.7, seed * 1.3))
    return noise.noise(q) + 0.5 * noise.noise(q * 2.03)


def build_piece(basemesh, piece, index, L, seed, materials):
    region = piece["region"]
    obj = copy_body(basemesh, f"cloth_{index}", lambda p, n: region(p, n) > -0.04)
    subdivide(obj)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    vals = cut(bm, region)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if face_value(f, vals) <= 0], context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    # Trim: cut along its line, the faces on its positive side take the trim slot.
    slot_of = {}
    if piece.get("trim"):
        tvals = cut(bm, piece["trim"])
        for f in bm.faces:
            slot_of[f] = piece["trim_slot"] if face_value(f, tvals) > 0 else piece["slot"]
    bm.normal_update()
    # Shape: thickness, looseness, folds; hem shading from the distance to the edge.
    shade = {}
    offset = piece["offset"]
    folds = piece.get("folds", 0.0)
    bm.verts.index_update()
    for v in bm.verts:
        p, n = G(v.co), G(v.normal)
        d = offset(n) if callable(offset) else offset
        if p.y < L["waist"]:
            d += piece.get("over_below_waist", 0.0) # worn outside the trousers below the belt line
        arm = abs(p.x) > L["shoulder"] + 0.02
        if arm:
            d += piece.get("sleeve", 0.0) * min(1.0, (abs(p.x) - L["shoulder"]) / max(L["wrist"] - L["shoulder"], 0.01))
        elif p.y < L["knee"]:
            d += piece.get("flare", 0.0) * max(0.0, min(1.0, (L["knee"] - p.y) / max(L["knee"] - L["ankle"], 0.01))) ** 1.3
        edge_fade = max(0.0, min(1.0, region(p, n) / 0.06))
        if folds:
            d += folds * edge_fade * fold(p, arm, seed)
            joint_x, joint_y = (L["elbow"], None) if arm else (None, L["knee"])
            if arm:
                d += folds * edge_fade * 0.9 * math.exp(-((abs(p.x) - L["elbow"]) / 0.04) ** 2) * math.sin(abs(p.x) * 220.0)
            elif p.y < L["hip"]:
                d += folds * edge_fade * 0.9 * math.exp(-((p.y - L["knee"]) / 0.05) ** 2) * math.sin(p.y * 200.0)
        v.co += v.normal * d
        r = region(p, n)
        shade[v] = HEM_SHADE + (1.0 - HEM_SHADE) * max(0.0, min(1.0, r / HEM_SHADE_DEPTH))
    if piece.get("flat_soles"):
        # A shoe, not a foot: smooth the toes and the arch into one rounded shape (the
        # opening at the top keeps its line), then sit the soles flat on the floor.
        # The toes are separate surfaces with crevices between them, which plain smoothing
        # can't fill: average each foot point with every point within 3 cm instead.
        from mathutils import kdtree
        foot = [v for v in bm.verts if not v.is_boundary and v.co.z < L["ankle"] + 0.03]
        for _ in range(4):
            tree = kdtree.KDTree(len(bm.verts))
            for v in bm.verts:
                tree.insert(v.co, v.index)
            tree.balance()
            cos = [v.co.copy() for v in bm.verts]
            for v in foot:
                near = tree.find_range(cos[v.index], 0.03)
                v.co = sum((c for c, _, _ in near), Vector()) / len(near)
        inner = [v for v in bm.verts if not v.is_boundary]
        for _ in range(6):
            bmesh.ops.smooth_vert(bm, verts=inner, factor=0.5, use_axis_x=True, use_axis_y=True, use_axis_z=True)
        bm.normal_update()
        for v in foot:
            v.co += v.normal * 0.006
        for v in bm.verts:
            if v.co.z < 0.018:
                v.co.z = 0.0
    # Hems turned inward, so the cloth shows a thickness.
    if piece.get("hem", True):
        bm.normal_update()
        boundary = [e for e in bm.edges if e.is_boundary]
        ret = bmesh.ops.extrude_edge_only(bm, edges=boundary)
        for v in [g for g in ret["geom"] if isinstance(g, bmesh.types.BMVert)]:
            v.co -= v.normal * 0.007
            shade[v] = HEM_SHADE * 0.85
        for f in [g for g in ret["geom"] if isinstance(g, bmesh.types.BMFace)]:
            slot_of.setdefault(f, piece["slot"])
    # Colour slots and hem shading.
    me = obj.data
    for f in bm.faces:
        f.material_index = slot_of.get(f, piece["slot"])
    bm.verts.index_update()
    shade_by_index = {v.index: shade.get(v, 1.0) for v in bm.verts}
    # Materials first: clearing the list afterwards would reset every face's slot to 0.
    me.materials.clear()
    for slot in range(4):
        me.materials.append(materials[slot])
    bm.to_mesh(me)
    bm.free()
    # Hem shading as a per-vertex colour (written through the mesh API: a bmesh colour
    # layer did not survive to the export).
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, value in shade_by_index.items():
        col.data[i].color = (value, value, value, 1.0)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = me.color_attributes.find("Col")
    return obj


def cloth_materials():
    return [bpy.data.materials.get(f"MI_Cloth_{s}") or bpy.data.materials.new(f"MI_Cloth_{s}") for s in SLOT_NAMES]


def belt_knot(basemesh, L, knot, materials):
    """Belt knot at the front centre plus two hanging ends, bound to the pelvis."""
    y = L["hip"] + knot["y"]
    pts = [basemesh.matrix_world @ v.co for v in basemesh.data.vertices if is_body(basemesh, v)]
    front = min((p for p in pts if abs(p.z - y) < 0.02 and abs(p.x) < 0.03), key=lambda p: p.y)
    centre = Vector((0.0, front.y - knot["offset"] - 0.012, y))
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(centre) @ Matrix.Diagonal((0.055, 0.03, 0.05, 1)))
    for side in (-1, 1):
        top_pt = centre + Vector((0.012 * side, -0.004, -0.018))
        bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(top_pt + Vector((0.03 * side, -0.004, -0.11))) @ Matrix.Rotation(0.18 * side, 4, "Y") @ Matrix.Diagonal((0.045, 0.006, 0.22, 1)))
    me = bpy.data.meshes.new("belt_knot")
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new("belt_knot", me)
    bpy.context.scene.collection.objects.link(obj)
    for m in materials:
        me.materials.append(m)
    for poly in me.polygons:
        poly.material_index = knot["slot"]
    g = obj.vertex_groups.new(name="pelvis")
    g.add(range(len(me.vertices)), 1.0, "REPLACE")
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv = (co.x * 6.0 + co.y * 6.0, co.z * 6.0)
    return obj


def beard(basemesh, L):
    """A short full beard cut from the face along an exact line: below the cheekbones, in
    front of the ears, the lips left bare. It keeps the body's face shapes, so it moves with
    the jaw."""
    lips = basemesh.vertex_groups["lips"].index
    head_group = basemesh.vertex_groups.get("head") or basemesh.vertex_groups.get("Head")
    lip_pts = [basemesh.matrix_world @ v.co for v in basemesh.data.vertices if any(e.group == lips and e.weight > 0.5 for e in v.groups)]
    lc = G(sum(lip_pts, Vector()) / len(lip_pts))

    def field(p, n):
        outer = min((lc.y + 0.03) - p.y, p.y - (lc.y - 0.09), p.z - (lc.z - 0.072), 0.074 - abs(p.x))
        lips_hole = math.hypot(p.x / 0.031, (p.y - lc.y) / 0.015) - 1.0 # positive outside the lips
        return min(outer, lips_hole * 0.015)
    obj = copy_body(basemesh, "beard", lambda p, n: field(p, n) > -0.02, keep_shapes=True)
    hg = obj.vertex_groups.get(head_group.name)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    vals = cut(bm, field)
    deform = bm.verts.layers.deform.active
    doomed = [f for f in bm.faces if face_value(f, vals) <= 0 or any(v[deform].get(hg.index, 0.0) < 0.5 for v in f.verts)]
    bmesh.ops.delete(bm, geom=doomed, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.normal_update()
    layers = list(bm.verts.layers.shape.values())
    for v in bm.verts:
        p = G(v.co)
        r = max(0.0, min(1.0, field(p, G(v.normal)) / 0.012)) # thin at the edge, full inside
        rough = 0.002 * (noise.noise(Vector((p.x * 180, p.y * 180, p.z * 180))) + 1.0)
        dn = v.normal * (0.0015 + (0.004 + rough) * r)
        v.co += dn
        for layer in layers:
            v[layer] += dn
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.materials.clear()
    obj.data.materials.append(bpy.data.materials.get("MI_Hair_Beard") or bpy.data.materials.new("MI_Hair_Beard"))
    return obj


def make_outfit(fighter, basemesh, rig, log):
    L = landmarks(rig, basemesh)
    log("landmarks", {k: round(v, 3) for k, v in L.items()})
    spec = specs(fighter, L)
    materials = cloth_materials()
    seed = sum(ord(c) for c in fighter) % 97
    pieces = []
    for i, piece in enumerate(spec["pieces"]):
        pieces.append(build_piece(basemesh, piece, i, L, seed + i * 3.1, materials))
    if spec.get("belt_knot"):
        pieces.append(belt_knot(basemesh, L, spec["belt_knot"], materials))
    if spec.get("beard"):
        pieces.append(beard(basemesh, L))
    log("outfit:", ", ".join("%s %d faces" % (o.name, len(o.data.polygons)) for o in pieces))
    return pieces, L, spec


def hide_covered_skin(basemesh, spec, log):
    """Deletes body faces well inside a garment (HIDE_INSET from its edge)."""
    hidden = [p for p in spec["pieces"] if p.get("hide", True)]
    bm = bmesh.new()
    bm.from_mesh(basemesh.data)
    bm.normal_update()
    doomed = []
    for f in bm.faces:
        p, n = G(basemesh.matrix_world @ f.calc_center_median()), G(f.normal)
        if any(piece["region"](p, n) > HIDE_INSET for piece in hidden):
            doomed.append(f)
    bmesh.ops.delete(bm, geom=doomed, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(basemesh.data)
    bm.free()
    log("covered skin removed:", len(doomed), "faces")
