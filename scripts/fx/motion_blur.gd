@tool
class_name MotionBlur
extends CompositorEffect
## Per-object motion blur (docs/motion-blur-plan.md, phase 1): fast limbs smear along their
## path like film shot with a 180° shutter, slow and still things stay sharp. Runs after the
## 3D scene (before glow and tone mapping) on Godot's motion vectors; see motion_blur.glsl.
## Purely visual: the simulation never reads it.
##
## Put it on a camera with `MotionBlur.attach(camera, level)`; Settings.apply_motion_blur does
## that for the fight camera. A frame where the camera cuts (it jumps or turns sharply, as at
## a round reset or a replay) is left sharp.

## FILM is for film-quality recordings only (FilmWriter): every rendered frame (240 a second)
## blurs over exactly its own time, and the writer blends them into a 180° shutter.
enum Level { OFF, SUBTLE, CINEMATIC, FILM }
const LEVEL_NAMES := ["Off", "Subtle", "Cinematic"] # the choices players see
## Exposure per level, in seconds: Cinematic is a 180° shutter at 60 frames a second; FILM
## (-1) is one rendered frame, whatever the frame rate.
const SHUTTER := [0.0, 1.0 / 240.0, 1.0 / 120.0, -1.0]
## The longest smear at 1080 lines, in px (scaled with the render height).
const MAX_BLUR_1080 := [0.0, 32.0, 56.0, 96.0]
const SAMPLES := 13
const TILE := 16
## How much of the camera's own motion blurs the picture (a pan stays readable).
const CAMERA_WEIGHT := 0.35
## A camera move this big in one frame is a cut.
const CUT_DISTANCE := 0.6
const CUT_DEGREES := 25.0
const SOFT_DEPTH := 0.08 # m: how far apart two surfaces are before one hides the other

## Exposure in seconds (0 = off, below 0 = one rendered frame).
@export var shutter := SHUTTER[Level.CINEMATIC]
@export var max_blur_1080 := MAX_BLUR_1080[Level.CINEMATIC]
## 0 off; debug views: 1 the motion vectors as colour, 2 the blur vectors (object motion),
## 3 the camera's share alone, 4 depth.
@export_range(0, 4) var debug_view := 0
## Real seconds the last frame took (set every frame by a Watcher; 1/60 until then).
var frame_seconds := 1.0 / 60.0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _params: RID
var _last_view_projection := Projection.IDENTITY
var _last_camera := Transform3D()
var _has_last := false
var _frame := 0


## Keeps `frame_seconds` current: the effect itself runs on the render thread.
class Watcher extends Node:
	var effect: MotionBlur
	func _process(delta: float) -> void:
		# Real time, not game time: slow motion is filmed at a high frame rate, so it blurs less.
		effect.frame_seconds = clampf(delta / maxf(Engine.time_scale, 0.01), 1.0 / 1000.0, 0.1)


## Adds (or updates, or with OFF removes) the blur on `camera`. Returns the effect or null.
static func attach(camera: Camera3D, level: Level) -> MotionBlur:
	var effect: MotionBlur = null
	if camera.compositor:
		for e in camera.compositor.compositor_effects:
			if e is MotionBlur:
				effect = e
	if level == Level.OFF:
		if effect:
			effect.enabled = false
		return null
	if effect == null:
		effect = MotionBlur.new()
		if camera.compositor == null:
			camera.compositor = Compositor.new()
		var effects := camera.compositor.compositor_effects
		effects.append(effect)
		camera.compositor.compositor_effects = effects
		var watcher := Watcher.new()
		watcher.name = "MotionBlurWatcher"
		watcher.effect = effect
		watcher.process_mode = Node.PROCESS_MODE_ALWAYS
		camera.add_child(watcher)
	effect.enabled = true
	effect.shutter = SHUTTER[level]
	effect.max_blur_1080 = MAX_BLUR_1080[level]
	return effect


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_motion_vectors = true
	RenderingServer.call_on_render_thread(_create)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [_params, _sampler, _pipeline, _shader]:
			if rid.is_valid():
				_rd.free_rid(rid)


func _create() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var file: RDShaderFile = load("res://scripts/fx/motion_blur.glsl")
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("motion blur shader: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = _rd.sampler_create(state)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES)


const PARAMS_BYTES := 16 * 4 * 2 + 16 * 3


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid() or callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_frame += 1

	# This frame's view-projection, so reprojected UVs match Godot's motion vectors.
	# get_cam_projection() is already in the renderer's own convention (checked with the
	# debug views: the reprojected camera motion matches the motion vectors of the stage).
	var camera := scene.get_cam_transform()
	var projection := scene.get_cam_projection()
	var view_projection := projection * Projection(camera.affine_inverse())
	var cut := not _has_last \
			or camera.origin.distance_to(_last_camera.origin) > CUT_DISTANCE \
			or rad_to_deg((-camera.basis.z).angle_to(-_last_camera.basis.z)) > CUT_DEGREES
	var reproject := _last_view_projection * view_projection.inverse()
	_last_view_projection = view_projection
	_last_camera = camera
	_has_last = true
	if (cut or shutter == 0.0) and debug_view == 0:
		return

	var exposure := shutter / maxf(frame_seconds, 0.001) if shutter > 0.0 else 1.0
	if debug_view > 0:
		exposure = 1.0
	var max_blur := max_blur_1080 * size.y / 1080.0
	var data := PackedFloat32Array()
	data.append_array(_columns(projection.inverse()))
	data.append_array(_columns(reproject))
	data.append_array([size.x, size.y, 1.0 / size.x, 1.0 / size.y])
	data.append_array([exposure, max_blur, CAMERA_WEIGHT, float(debug_view)])
	data.append_array([float(SAMPLES), float(_frame % 64), SOFT_DEPTH, 1.0])
	_rd.buffer_update(_params, 0, data.size() * 4, data.to_byte_array())

	var tiles := Vector2i((size.x + TILE - 1) / TILE, (size.y + TILE - 1) / TILE)
	if buffers.has_texture(&"motion_blur", &"copy"):
		var existing := buffers.get_texture_format(&"motion_blur", &"copy")
		if existing.width != size.x or existing.height != size.y:
			buffers.clear_context(&"motion_blur")
	if not buffers.has_texture(&"motion_blur", &"copy"):
		var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		buffers.create_texture(&"motion_blur", &"copy", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
		buffers.create_texture(&"motion_blur", &"vectors", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
		buffers.create_texture(&"motion_blur", &"tile", RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, tiles, 1, 1, true, false)
		buffers.create_texture(&"motion_blur", &"neighbour", RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, tiles, 1, 1, true, false)

	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var velocity := buffers.get_velocity_layer(view)
		var depth := buffers.get_depth_layer(view)
		if not velocity.is_valid() or not depth.is_valid():
			return
		var uniforms := [
			_image(0, color),
			_image(1, buffers.get_texture_slice(&"motion_blur", &"copy", view, 0, 1, 1)),
			_image(2, velocity),
			_sampled(3, depth),
			_image(4, buffers.get_texture_slice(&"motion_blur", &"tile", view, 0, 1, 1)),
			_image(5, buffers.get_texture_slice(&"motion_blur", &"neighbour", view, 0, 1, 1)),
			_buffer(6, _params),
			_image(7, buffers.get_texture_slice(&"motion_blur", &"vectors", view, 0, 1, 1)),
		]
		var set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, set, 0)
		for pass_id in 4:
			var push := PackedInt32Array([pass_id, 0, 0, 0]).to_byte_array()
			_rd.compute_list_set_push_constant(list, push, push.size())
			var groups := (tiles + Vector2i(7, 7)) / 8 if pass_id in [1, 2] else (size + Vector2i(7, 7)) / 8
			_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
			_rd.compute_list_add_barrier(list)
		_rd.compute_list_end()


static func _columns(p: Projection) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for column in [p.x, p.y, p.z, p.w]:
		out.append_array([column.x, column.y, column.z, column.w])
	return out


func _image(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(texture)
	return u


func _sampled(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(texture)
	return u


func _buffer(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u
