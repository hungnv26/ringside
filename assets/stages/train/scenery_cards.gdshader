// Train stage trees drawn as crossed cards of the tree atlas (tools/make_train_art.py),
// streaming past like the rest of the scenery (scenery.gdshader: each instance slides along
// -X by `scroll` and jumps back by `period`). UV picks the atlas cell; alpha-tested, both
// sides drawn, the low sun shining through the leaves.
shader_type spatial;
render_mode world_vertex_coords, cull_disabled;

uniform float scroll = 0.0;
uniform float period = 480.0;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 albedo : source_color = vec4(1.0);
uniform vec3 backlight : source_color = vec3(0.25, 0.3, 0.12);

void vertex() {
	float origin = MODEL_MATRIX[3].x;
	float moved = mod(origin - scroll + period * 0.5, period) - period * 0.5;
	VERTEX.x += moved - origin;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * albedo.rgb * COLOR.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
	BACKLIGHT = backlight;
}
