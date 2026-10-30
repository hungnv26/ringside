extends SceneTree
## Builds the project UI theme (res://assets/ui/theme.tres, set as gui/theme/custom in
## project.godot): Barlow Condensed (SIL Open Font Licence, assets/ui/fonts) for every label
## and button, SemiBold by default, with the system fonts as a fallback for symbols the
## typeface lacks (★ ◆ ◇ and the direction arrows in move lists). Phase 5,
## docs/graphics-plan.md.
##
## Run: godot --headless --path . -s res://tools/build_ui_theme.gd

const OUT := "res://assets/ui/theme.tres"
const FONTS := "res://assets/ui/fonts/"


func _initialize() -> void:
	var symbols := SystemFont.new()
	symbols.font_names = PackedStringArray(["Apple Symbols", "Segoe UI Symbol", "DejaVu Sans", "Noto Sans Symbols 2", "sans-serif"])
	var fonts := {}
	for weight in ["Medium", "SemiBold", "Bold"]:
		# A variation of the font carries the fallback (the imported .ttf can't keep one).
		var variation := FontVariation.new()
		variation.base_font = load(FONTS + "BarlowCondensed-%s.ttf" % weight)
		variation.fallbacks = [symbols]
		fonts[weight] = variation
	var theme := Theme.new()
	theme.default_font = fonts["SemiBold"]
	# Buttons and the HUD's names read a step heavier.
	theme.set_font("font", "Button", fonts["Bold"])
	ResourceSaver.save(theme, OUT)
	print("saved ", OUT)
	quit()
