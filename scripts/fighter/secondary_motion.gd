class_name SecondaryMotion
extends RefCounted
## Secondary motion (docs/movement-plan.md, phase 3): long hair and belt tails swing on
## spring bones. The fighters' hair and belts are rigid meshes skinned to the head or the
## pelvis, so at load time this adds a short chain of bones down the hanging part of each
## mesh, re-skins the hanging vertices to it, and hands the chains to a
## SpringBoneSimulator3D, which runs after the motion layer. Cosmetic only. Short hair and
## knots without tails get no chain.

## [mesh name, parent bone, how far below the parent a vertex must hang (m), longest
## segment (m), stiffness, drag, gravity]
const CHAINS := [
	["hair", "Head", 0.05, 0.11, 2.6, 0.6, 0.5],
	["belt_knot", "pelvis", 0.03, 0.08, 1.0, 0.35, 0.6],
]
const MIN_HANG := 0.08 # a hanging part shorter than this keeps still
const MIN_VERTICES := 4
## Bodies the hair and tails bounce off: bone, radius (sized so a joint touches about the
## skin, not inside it: too big and the hair is pushed out from the back), offset.
const COLLIDERS := [
	["Head", 0.1, Vector3.ZERO],
	["neck_01", 0.05, Vector3.ZERO],
	["spine_03", 0.07, Vector3.ZERO],
	["spine_02", 0.07, Vector3.ZERO],
	["spine_01", 0.07, Vector3.ZERO],
	["pelvis", 0.09, Vector3.ZERO],
	["clavicle_l", 0.05, Vector3.ZERO],
	["clavicle_r", 0.05, Vector3.ZERO],
	["upperarm_l", 0.05, Vector3.ZERO],
	["upperarm_r", 0.05, Vector3.ZERO],
	["thigh_l", 0.07, Vector3.ZERO],
	["thigh_r", 0.07, Vector3.ZERO],
]


## Adds the chains and the simulator to a built model. Returns the simulator (or null).
static func add_to(skeleton: Skeleton3D) -> SpringBoneSimulator3D:
	var chains := [] # [root bone, end bone, stiffness, drag, gravity, tip length]
	for spec: Array in CHAINS:
		for mesh: MeshInstance3D in skeleton.find_children(spec[0], "MeshInstance3D", true, false):
			var chain := _rig(skeleton, mesh, spec)
			if not chain.is_empty():
				chains.append(chain)
	if chains.is_empty():
		return null
	var sim := SpringBoneSimulator3D.new()
	sim.name = "Springs"
	skeleton.add_child(sim)
	sim.setting_count = chains.size()
	for i in chains.size():
		var c: Array = chains[i]
		sim.set_root_bone(i, c[0])
		sim.set_end_bone(i, c[1])
		sim.set_extend_end_bone(i, true)
		sim.set_end_bone_direction(i, SpringBoneSimulator3D.BONE_DIRECTION_FROM_PARENT)
		sim.set_end_bone_length(i, c[5])
		sim.set_stiffness(i, c[2])
		sim.set_drag(i, c[3])
		sim.set_gravity(i, c[4])
		sim.set_radius(i, 0.03)
		sim.set_enable_all_child_collisions(i, true)
	for col: Array in COLLIDERS:
		var bone := skeleton.find_bone(col[0])
		if bone < 0:
			continue
		var sphere := SpringBoneCollisionSphere3D.new()
		sim.add_child(sphere)
		sphere.set_bone(bone)
		sphere.set_radius(col[1])
		sphere.set_position_offset(col[2])
	return sim


## Builds one chain for one mesh: returns [root, end, stiffness, drag, gravity, tip length]
## or [] when nothing hangs far enough.
static func _rig(skeleton: Skeleton3D, mesh: MeshInstance3D, spec: Array) -> Array:
	var parent_bone := skeleton.find_bone(spec[1])
	var skin := mesh.skin
	if parent_bone < 0 or skin == null or mesh.mesh == null or mesh.mesh.get_blend_shape_count() > 0:
		return []
	var parent_bind := -1
	for b in skin.get_bind_count():
		if skin.get_bind_bone(b) == parent_bone or skin.get_bind_name(b) == StringName(spec[1]):
			parent_bind = b
	if parent_bind < 0:
		return []
	var parent_rest := skeleton.get_bone_global_rest(parent_bone)
	# Mesh space -> skeleton space (the same for every bind at rest).
	var to_skeleton := parent_rest * skin.get_bind_pose(parent_bind)
	var anchor_y := parent_rest.origin.y - float(spec[2])
	var anchor_z := parent_rest.origin.z + 0.03 # behind the face only (+Z is forward)

	# The hanging vertices, over every surface.
	var hanging := PackedVector3Array()
	var surfaces := []
	for s in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(s)
		surfaces.append(arrays)
		for v: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			var p := to_skeleton * v
			if p.y < anchor_y and (spec[0] != "hair" or p.z < anchor_z):
				hanging.append(p)
	if hanging.size() < MIN_VERTICES:
		if OS.has_environment("SPRING_DEBUG"):
			print("spring %s: %d hanging below %.3f" % [mesh.name, hanging.size(), anchor_y])
		return []
	# The hanging part starts at the anchor line (a belt tail is a strip with vertices only
	# at its ends, so its own vertices don't show where it starts).
	var top := anchor_y
	var bottom := INF
	for p in hanging:
		bottom = minf(bottom, p.y)
	var hang := top - bottom
	if hang < MIN_HANG:
		if OS.has_environment("SPRING_DEBUG"):
			print("spring %s: hangs %.3f (%.3f..%.3f)" % [mesh.name, hang, bottom, top])
		return []

	# Chain points: the centre of the hanging part at evenly spaced heights.
	var segments := clampi(ceili(hang / float(spec[3])), 2, 5)
	var points := []
	for k in segments + 1:
		var y := top - hang * float(k) / segments
		var sum := Vector3.ZERO
		var n := 0
		for p in hanging:
			if absf(p.y - y) < hang / segments * 0.6:
				sum += p
				n += 1
		points.append(sum / n if n > 0 else Vector3(parent_rest.origin.x, y, parent_rest.origin.z - 0.08))
	# The chain hangs from where the hair leaves the head: start it a little above the top.
	points[0] = (points[0] as Vector3) + Vector3.UP * 0.02

	# Bones: a chain of `segments` bones under the parent, plus the tip handled as an extension.
	# Each bone's +Y points down the chain to the next point (the spring solver's bone axis).
	var globals := []
	for k in segments:
		var along: Vector3 = ((points[k + 1] as Vector3) - (points[k] as Vector3)).normalized()
		var side := along.cross(Vector3.BACK)
		if side.length_squared() < 1e-6:
			side = along.cross(Vector3.RIGHT)
		side = side.normalized()
		globals.append(Transform3D(Basis(side, along, side.cross(along).normalized()), points[k]))
	var base := "%s_%s" % [mesh.name, spec[1]]
	var bones := []
	var parent_global := parent_rest
	var prev := parent_bone
	for k in segments:
		var bone_name := "%s_spring_%d" % [base, k]
		var idx := skeleton.find_bone(bone_name)
		if idx < 0:
			idx = skeleton.get_bone_count()
			skeleton.add_bone(bone_name)
		skeleton.set_bone_parent(idx, prev)
		var global: Transform3D = globals[k]
		skeleton.set_bone_rest(idx, parent_global.affine_inverse() * global)
		skeleton.reset_bone_pose(idx)
		bones.append(idx)
		parent_global = global
		prev = idx

	# Skin: a bind per new bone, then the hanging vertices re-weighted along the chain.
	var new_skin := skin.duplicate() as Skin
	var binds := []
	for k in segments:
		var global: Transform3D = globals[k]
		binds.append(new_skin.get_bind_count())
		new_skin.add_named_bind(skeleton.get_bone_name(bones[k]), global.affine_inverse() * to_skeleton)
	var new_mesh := ArrayMesh.new()
	for s in surfaces.size():
		var arrays: Array = surfaces[s]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var vb: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var vw: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var per := vb.size() / maxi(verts.size(), 1)
		for i in verts.size():
			var p := to_skeleton * verts[i]
			if p.y >= anchor_y or (spec[0] == "hair" and p.z >= anchor_z):
				continue
			# Position along the chain (0 at its root), and how fully it hangs.
			var along := clampf((top + 0.02 - p.y) / (hang + 0.02) * segments, 0.0, segments - 0.001)
			var k := int(along)
			var f := along - k
			var share := smoothstep(0.0, 0.04, anchor_y - p.y)
			var weights := {}
			for j in per:
				var w := vw[i * per + j] * (1.0 - share)
				if w > 0.0:
					weights[vb[i * per + j]] = weights.get(vb[i * per + j], 0.0) + w
			var b0: int = binds[k]
			var b1: int = binds[mini(k + 1, segments - 1)]
			weights[b0] = weights.get(b0, 0.0) + share * (1.0 - f)
			weights[b1] = weights.get(b1, 0.0) + share * f
			var order := weights.keys()
			order.sort_custom(func(a, b): return weights[a] > weights[b])
			var total := 0.0
			for j in mini(per, order.size()):
				total += weights[order[j]]
			for j in per:
				if j < order.size() and total > 0.0:
					vb[i * per + j] = order[j]
					vw[i * per + j] = weights[order[j]] / total
				else:
					vb[i * per + j] = 0
					vw[i * per + j] = 0.0
		arrays[Mesh.ARRAY_BONES] = vb
		arrays[Mesh.ARRAY_WEIGHTS] = vw
		var flags: int = mesh.mesh.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		new_mesh.add_surface_from_arrays(mesh.mesh.surface_get_primitive_type(s), arrays, [], {}, flags)
		new_mesh.surface_set_material(s, mesh.mesh.surface_get_material(s))
		new_mesh.surface_set_name(s, mesh.mesh.surface_get_name(s))
	var overrides := []
	for s in mesh.get_surface_override_material_count():
		overrides.append(mesh.get_surface_override_material(s))
	mesh.mesh = new_mesh
	mesh.skin = new_skin
	for s in overrides.size():
		mesh.set_surface_override_material(s, overrides[s])
	var tip := (points[segments] as Vector3).distance_to(points[segments - 1])
	return [bones[0], bones[segments - 1], spec[4], spec[5], spec[6], maxf(tip, 0.03)]
