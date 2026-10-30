class_name HudStyle
extends RefCounted
## The fight HUD's look in one place (Phase 5, docs/graphics-plan.md), shared by the
## fight HUD (fight_hud.gd) and the coach overlay (coach_link.gd): dark translucent panels
## with a thin warm edge, small square corners, Barlow Condensed (the project theme), gold
## for the one accent. Kept from the HUD conventions: real data only, no neon, no glow, no
## moving lights.

const PANEL_BG := Color(0.055, 0.06, 0.075, 0.86)
const PANEL_EDGE := Color(0.36, 0.33, 0.27)
const ACCENT := Color(0.98, 0.8, 0.32)
const TEXT := Color(0.94, 0.92, 0.88)
const TEXT_DIM := Color(0.7, 0.68, 0.64)
const HEALTH_TOP := Color(1.0, 0.88, 0.38)
const HEALTH_BOTTOM := Color(0.92, 0.62, 0.1)
const HEALTH_LOW_TOP := Color(1.0, 0.55, 0.3)
const HEALTH_LOW_BOTTOM := Color(0.82, 0.22, 0.1)
const TRAIL := Color(0.78, 0.12, 0.1)


## A panel: background, a 1 px edge (`edge` 0 for none), padding, a little rounding.
static func panel(padding := Vector2(14, 8), edge := 1, radius := 4, background := PANEL_BG) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = background
	box.border_color = PANEL_EDGE
	box.set_border_width_all(edge)
	box.set_corner_radius_all(radius)
	box.content_margin_left = padding.x
	box.content_margin_right = padding.x
	box.content_margin_top = padding.y
	box.content_margin_bottom = padding.y
	return box


## A plan chip (coach overlay): a small tag.
static func chip() -> StyleBoxFlat:
	return panel(Vector2(7, 2), 1, 3, Color(0.05, 0.055, 0.07, 0.82))


## A bar's fill: a vertical gradient from `top` to `bottom`, with a pale line at the top
## edge so the bar reads as a lit, rounded strip (static: no shine moves along it).
static func bar_fill(top: Color, bottom: Color) -> StyleBoxTexture:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.12, 0.2, 1.0])
	gradient.colors = PackedColorArray([top.lightened(0.45), top, top, bottom])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0, 0)
	texture.fill_to = Vector2(0, 1)
	texture.width = 4
	texture.height = 64
	var box := StyleBoxTexture.new()
	box.texture = texture
	return box


## A label set in the theme's typeface at `size`, with an outline for legibility over
## the fight.
static func label(size: int, color := TEXT, outline := 6) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", outline)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	return l
