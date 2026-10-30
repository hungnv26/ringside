"""Turns Poly Haven's Jacaranda Tree (CC0, about 3.9 million triangles) into the Temple's
cherry tree for the game (about 40,000):

1. The trunk and branches are decimated (the bark textures stay).
2. The 2.4 million modelled leaves are replaced by blossom cards: the leaves' points are
   grouped into cells of CELL metres, and each cell with enough leaves gets two crossed cards
   of the blossom atlas (tools/blender/make_blossom_texture.py), random cell of the atlas,
   random turn. Card normals point away from the crown's centre (foliage shading reads as
   one soft canopy), and the vertex colour carries a brightness variation (rgb) and how far
   the card sways in the wind (alpha: more at the tips, less near the trunk).
3. Scaled to HEIGHT metres, trunk base at the origin, exported as glTF with its textures.

    Blender -b --python tools/blender/build_cherry_tree.py -- <jacaranda_tree_1k.gltf> <out.gltf>
"""
import math
import os
import random
import sys

import bmesh
import bpy
import numpy as np

HEIGHT = 6.8
CELL = 0.42           # metres per leaf cell (before scaling)
MIN_LEAF_POINTS = 40  # cells with fewer leaf points get no card
CARD_SIZE = (1.5, 2.0)  # card edge, times the cell
# Only the canopy's outer shell gets cards: per direction from the crown's centre, cells at
# least SHELL of that direction's furthest cell. Cards inside the canopy are never seen but
# cost as much as the outer ones (alpha-tested overdraw, and again in every shadow pass).
SHELL = 0.84
DIRECTION_BINS = (20, 10)
BRANCH_TRIANGLES = 40000
TRUNK_TRIANGLES = 6000


def log(*a):
    print("TREE", *a, flush=True)


def separate(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="MATERIAL")
    bpy.ops.object.mode_set(mode="OBJECT")
    return {o.active_material.name: o for o in bpy.context.scene.objects if o.type == "MESH"}


def decimate(obj, target):
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    m = obj.modifiers.new("Decimate", "DECIMATE")
    m.ratio = min(1.0, target / max(tris, 1))
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier="Decimate")
    log(obj.name, "decimated", tris, "->", sum(len(p.vertices) - 2 for p in obj.data.polygons))


def blossom_cards(leaves, atlas_path):
    me = leaves.data
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    keys = np.floor(co / CELL).astype(np.int64)
    uniq, inverse, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    inverse = inverse.reshape(-1)
    centres = np.zeros((len(uniq), 3))
    for axis in range(3):
        centres[:, axis] = np.bincount(inverse, weights=co[:, axis]) / counts
    keep = counts >= MIN_LEAF_POINTS
    centres = centres[keep]
    crown = co.mean(axis=0)
    crown_low, crown_high = co[:, 2].min(), co[:, 2].max()
    rel = centres - crown
    dist = np.linalg.norm(rel, axis=1)
    theta = np.floor((np.arctan2(rel[:, 1], rel[:, 0]) + math.pi) / (2 * math.pi) * DIRECTION_BINS[0]).astype(int) % DIRECTION_BINS[0]
    phi = np.clip(np.floor((rel[:, 2] / np.maximum(dist, 1e-6) + 1.0) / 2.0 * DIRECTION_BINS[1]).astype(int), 0, DIRECTION_BINS[1] - 1)
    bins = theta * DIRECTION_BINS[1] + phi
    furthest = np.zeros(DIRECTION_BINS[0] * DIRECTION_BINS[1])
    np.maximum.at(furthest, bins, dist)
    shell = dist >= SHELL * furthest[bins]
    log("leaf points", len(co), "cells", len(uniq), "with leaves", len(centres), "shell cards", int(shell.sum()))
    centres = centres[shell]

    rng = random.Random(1868)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    col_layer = bm.loops.layers.float_color.new("Col")
    normals = []
    for c in centres:
        size = CELL * rng.uniform(*CARD_SIZE)
        cell = rng.randrange(4)
        u0, v0 = (cell % 2) * 0.5, (cell // 2) * 0.5
        out = c - crown
        out[2] *= 0.6
        n_out = out / (np.linalg.norm(out) + 1e-6)
        n_out = (n_out + np.array([0.0, 0.0, 0.6]))
        n_out /= np.linalg.norm(n_out)
        bright = rng.uniform(0.82, 1.05)
        sway = float(np.clip((c[2] - crown_low) / (crown_high - crown_low + 1e-6), 0.2, 1.0))
        # One card facing out of the canopy (turned a little at random), spun in its plane.
        facing = n_out + np.array([rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), rng.uniform(-0.2, 0.2)])
        facing /= np.linalg.norm(facing)
        side = np.cross(np.array([0.0, 0.0, 1.0]), facing)
        if np.linalg.norm(side) < 1e-3:
            side = np.array([1.0, 0.0, 0.0])
        side /= np.linalg.norm(side)
        lift = np.cross(facing, side)
        spin = rng.random() * math.tau
        right = side * math.cos(spin) + lift * math.sin(spin)
        up = -side * math.sin(spin) + lift * math.cos(spin)
        h = size / 2
        corners = [c - right * h - up * h, c + right * h - up * h, c + right * h + up * h, c - right * h + up * h]
        verts = [bm.verts.new(tuple(p)) for p in corners]
        face = bm.faces.new(verts)
        uvs = [(u0, v0), (u0 + 0.5, v0), (u0 + 0.5, v0 + 0.5), (u0, v0 + 0.5)]
        for loop, uv in zip(face.loops, uvs):
            loop[uv_layer].uv = uv
            loop[col_layer] = (bright, bright, bright, sway)
        normals.extend([tuple(n_out)] * 4)
    mesh = bpy.data.meshes.new("Blossom")
    bm.to_mesh(mesh)
    bm.free()
    mesh.normals_split_custom_set_from_vertices(normals)
    obj = bpy.data.objects.new("Blossom", mesh)
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("Blossom")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(os.path.abspath(atlas_path))
    mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    mat.node_tree.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    mat.blend_method = "CLIP" if hasattr(mat, "blend_method") else None
    mesh.materials.append(mat)
    return obj


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, out = argv[0], argv[1]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    tree = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    bpy.context.view_layer.objects.active = tree
    tree.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    parts = separate(tree)
    log("parts", {k: len(v.data.polygons) for k, v in parts.items()})
    leaves = parts["jacaranda_tree_leaves"]
    atlas = os.path.join(os.path.dirname(out), "textures", "blossom.png")
    blossom = blossom_cards(leaves, atlas)
    bpy.data.objects.remove(leaves)
    decimate(parts["jacaranda_tree_branches"], BRANCH_TRIANGLES)
    decimate(parts["jacaranda_tree_trunk"], TRUNK_TRIANGLES)
    # Scale to HEIGHT, trunk base at the origin.
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    zs = np.concatenate([[(o.matrix_world @ v.co).z for v in o.data.vertices] for o in objs])
    trunk = parts["jacaranda_tree_trunk"]
    tco = np.array([v.co[:] for v in trunk.data.vertices])
    base = tco[tco[:, 2] < tco[:, 2].min() + 0.3].mean(axis=0)
    scale = HEIGHT / (zs.max() - zs.min())
    log("height", round(zs.max() - zs.min(), 2), "scale", round(scale, 3))
    for o in objs:
        for v in o.data.vertices:
            p = (np.array(v.co[:]) - np.array([base[0], base[1], zs.min()])) * scale
            v.co = p
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              export_yup=True, export_vertex_color="ACTIVE", export_all_vertex_colors=False)
    log("exported", out, {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs})


main()
