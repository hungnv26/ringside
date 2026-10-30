class_name StageLook
extends RefCounted
## Each stage's light at the High and Showcase presets (docs/graphics-plan.md, phase 1):
## ambient occlusion so fighters and props sit on the floor, screen-space indirect light so
## coloured surfaces bounce onto their neighbours, reflections only where the floor is
## polished or wet, a slightly soft sun (a large one washed long shadows out), and at Showcase real-time
## global illumination (SDFGI). Applied at run time to a copy of the stage's environment, so
## the stage scenes (built by tools/build_*_stage.gd) stay as they are.
##
## Measured on an M1 Pro at a 3200×1800 window (tools/look_capture.gd): at native resolution
## ambient occlusion costs about 2.5 ms, indirect light and reflections 5 to 6 ms each and
## SDFGI about 9 ms; High draws the 3D at 1080p and upscales it (MetalFX on a Mac), which
## pays for all three with room to spare.

## Per stage (scene file name): ao and ssil are intensities, ssr turns reflections on,
## sun is the key light's apparent size in degrees (bigger: softer shadows), gi is the
## SDFGI energy at Showcase (0 leaves it off: the Ring's stands have no lamp of their own and
## go black once SDFGI replaces the flat ambient light), grade nudges the stage's own grade.
const PROFILES := {
	"ring": {ao = 2.2, ssil = 0.9, ssr = false, sun = 0.0, gi = 0.0},
	"dojo": {ao = 2.0, ssil = 1.2, ssr = true, sun = 0.0, gi = 0.9},
	"rooftop": {ao = 1.8, ssil = 0.8, ssr = true, sun = 0.0, gi = 0.7},
	"temple": {ao = 1.8, ssil = 1.0, ssr = false, sun = 0.35, gi = 0.8, grade = {saturation = -0.12}},
	"beach": {ao = 1.5, ssil = 1.0, ssr = false, sun = 0.3, gi = 0.95},
	"market": {ao = 2.0, ssil = 1.1, ssr = false, sun = 0.0, gi = 0.8},
	"train": {ao = 1.6, ssil = 0.9, ssr = true, sun = 0.35, gi = 0.95},
	"courtyard": {ao = 2.0, ssil = 1.1, ssr = false, sun = 0.35, gi = 0.8},
}
const DEFAULT := {ao = 1.8, ssil = 1.0, ssr = false, sun = 0.3, gi = 0.8}


static func profile(stage: Node) -> Dictionary:
	var key := stage.scene_file_path.get_file().get_basename()
	return PROFILES.get(key, DEFAULT)


## showcase: SDFGI and the richer settings on top of High.
static func apply(stage: Node, showcase: bool) -> void:
	var p := profile(stage)
	for node in stage.find_children("*", "WorldEnvironment", true, false):
		var world := node as WorldEnvironment
		if world.environment == null:
			continue
		var env := world.environment.duplicate() as Environment
		world.environment = env
		env.ssao_enabled = true
		env.ssao_radius = 1.1
		env.ssao_intensity = float(p.ao)
		env.ssao_power = 1.6
		env.ssao_detail = 0.6
		env.ssao_horizon = 0.08
		env.ssao_sharpness = 0.98
		env.ssao_light_affect = 0.35 # occlusion in lit areas too: contact darkening under feet and props
		env.ssao_ao_channel_affect = 0.4
		env.ssil_enabled = true
		env.ssil_radius = 4.0
		env.ssil_intensity = float(p.ssil)
		env.ssil_sharpness = 0.98
		env.ssil_normal_rejection = 1.0
		if p.ssr:
			env.ssr_enabled = true
			env.ssr_max_steps = 96 if showcase else 64
			env.ssr_fade_in = 0.15
			env.ssr_fade_out = 2.0
			env.ssr_depth_tolerance = 0.25
		if showcase and float(p.gi) > 0.0:
			env.sdfgi_enabled = true
			env.sdfgi_use_occlusion = true
			env.sdfgi_cascades = 4
			env.sdfgi_min_cell_size = 0.15
			env.sdfgi_energy = float(p.gi)
			env.sdfgi_bounce_feedback = 0.4
		var grade: Dictionary = p.get("grade", {})
		if not grade.is_empty():
			env.adjustment_enabled = true
			env.adjustment_saturation += float(grade.get("saturation", 0.0))
			env.adjustment_contrast += float(grade.get("contrast", 0.0))
			env.adjustment_brightness += float(grade.get("brightness", 0.0))
	if float(p.sun) > 0.0:
		for node in stage.find_children("*", "DirectionalLight3D", true, false):
			var sun := node as DirectionalLight3D
			if sun.shadow_enabled:
				sun.light_angular_distance = float(p.sun)
				break
