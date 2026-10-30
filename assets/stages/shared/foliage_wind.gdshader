// Foliage cards in the wind (the Temple's cherry blossom, tools/blender/build_cherry_tree.py):
// alpha-tested cards whose vertex colour carries a brightness (rgb) and how far the card
// sways (alpha: more at the crown's tips). The sway is a slow gust that travels across the
// stage plus a quick flutter per card; light coming from behind shines through (BACKLIGHT).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec3 tint : source_color = vec3(1.0);
uniform float sway = 0.06; // metres at the tips
uniform float gust_speed = 0.9;
uniform vec2 gust_dir = vec2(0.8, 0.3);
uniform vec3 backlight : source_color = vec3(0.45, 0.28, 0.3);
uniform float alpha_cut = 0.42;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = COLOR.a;
	float phase = dot(world.xz, gust_dir) * 0.35;
	float gust = sin(TIME * gust_speed - phase) * 0.6 + sin(TIME * gust_speed * 2.3 - phase * 1.7) * 0.4;
	float flutter = sin(TIME * 7.0 + world.x * 13.0 + world.y * 7.0 + world.z * 11.0);
	VERTEX.x += (gust * gust_dir.x * sway + flutter * 0.006) * w;
	VERTEX.z += (gust * gust_dir.y * sway + flutter * 0.006) * w;
	VERTEX.y += flutter * 0.004 * w;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * COLOR.rgb * tint;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;

	ROUGHNESS = 0.75;
	BACKLIGHT = backlight;
}
