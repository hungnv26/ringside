class_name ScreenFx
extends CanvasLayer
## Full-screen fight effects over the 3D view (assets/fx/screen_fx.gdshader), under the HUD:
## impact frames, heat-distortion shockwaves, and the darkened background of a super's
## freeze. Cosmetic, real time, hidden (so free) while nothing is running. Off with the
## action camera (Settings camera mode Off), which is also the "calmer" setting.

const SHADER := "res://assets/fx/screen_fx.gdshader"
## How long an impact frame holds (real seconds: two frames at 60 fps).
const IMPACT_SECONDS := 0.034
const SHOCK_SECONDS := 0.32

var _rect: ColorRect
var _mat: ShaderMaterial
var _impact := 0.0
var _shock_time := -1.0
var _shock_strength := 0.0
var _shock_point := Vector3.ZERO
var _darken := 0.0
var _darken_time := 0.0
var _darken_fighter: Node3D
## Impact frames shown (tests).
var impact_frames := 0


func _ready() -> void:
	layer = -1 # under the HUD
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER)
	_rect = ColorRect.new()
	_rect.name = "ScreenEffect"
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_rect)
	_rect.visible = false


func _enabled() -> bool:
	var settings := get_tree().root.get_node_or_null("Settings") if is_inside_tree() else null
	return settings == null or int(settings.get("camera_mode")) != ActionCamera.Mode.OFF


## One or two frames of a high-contrast frame, tinted `tint`.
func impact_frame(tint: Color) -> void:
	if not _enabled():
		return
	impact_frames += 1
	_impact = IMPACT_SECONDS
	_mat.set_shader_parameter("impact_tint", Vector3(tint.r, tint.g, tint.b))


## A ring of heat distortion spreading from the world point `at`.
func shockwave(at: Vector3, strength: float) -> void:
	if not _enabled():
		return
	_shock_point = at
	_shock_time = 0.0
	_shock_strength = strength


## Darkens everything but `fighter` for `seconds` (a super's freeze), easing in and out.
func darken_on(fighter: Node3D, seconds: float) -> void:
	if not _enabled():
		return
	_darken_fighter = fighter
	_darken_time = seconds


func _process(scaled_delta: float) -> void:
	var delta := scaled_delta / maxf(Engine.time_scale, 0.01) # real time, through slow motion
	var camera := get_viewport().get_camera_3d()
	var size := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("aspect", size.x / maxf(size.y, 1.0))
	_impact = maxf(_impact - delta, 0.0)
	_mat.set_shader_parameter("impact", 1.0 if _impact > 0.0 else 0.0)
	var shock := 0.0
	if _shock_time >= 0.0 and camera:
		_shock_time += delta
		var t := _shock_time / SHOCK_SECONDS
		if t >= 1.0 or camera.is_position_behind(_shock_point):
			_shock_time = -1.0
		else:
			var at := camera.unproject_position(_shock_point) / size
			_mat.set_shader_parameter("shock_center", at)
			_mat.set_shader_parameter("shock_radius", 0.03 + 0.45 * (1.0 - pow(1.0 - t, 2.0)))
			shock = _shock_strength * (1.0 - t)
	_mat.set_shader_parameter("shock_strength", shock)
	_darken_time = maxf(_darken_time - delta, 0.0)
	var target := 1.0 if _darken_time > 0.08 else 0.0
	_darken = move_toward(_darken, target, delta * (6.0 if target > _darken else 4.0))
	if _darken > 0.0 and camera and is_instance_valid(_darken_fighter):
		var chest := _darken_fighter.global_position + Vector3.UP * 1.1
		if not camera.is_position_behind(chest):
			_mat.set_shader_parameter("focus_center", camera.unproject_position(chest) / size)
	_mat.set_shader_parameter("darken", _darken)
	_rect.visible = _impact > 0.0 or shock > 0.0 or _darken > 0.0


## True while any effect is showing (tests).
func active() -> bool:
	return _rect.visible
