// Distant mountain ridges in haze (the Temple, the Express): unlit, in the ring's haze colour, with an
// aerial rock-and-grass texture's brightness as detail (projected along the three world axes
// and blended by the normal). Fog is off: the colour already is the haze.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 haze = vec3(0.5, 0.35, 0.4); // linear, as the old vertex-coloured ridges were
uniform vec3 peak_light = vec3(0.95, 0.7, 0.6);
uniform float detail = 0.45; // how much the texture shows
uniform float scale = 0.022; // texture repeats per metre
uniform float peak_height = 30.0;
// Optional: scenery that streams past (the Express; scenery.gdshader's loop). Each object
// slides along -X by `scroll` and jumps back by `period` (0 = standing still).
uniform float scroll = 0.0;
uniform float period = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	if (period > 0.0) {
		float origin = MODEL_MATRIX[3].x;
		float moved = mod(origin - scroll + period * 0.5, period) - period * 0.5;
		VERTEX.x += moved - origin; // the segments aren't rotated or scaled
	}
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = abs(normalize(world_normal));
	w /= (w.x + w.y + w.z);
	vec3 p = world_pos * scale;
	vec3 t = texture(detail_tex, p.zy).rgb * w.x + texture(detail_tex, p.xz).rgb * w.y + texture(detail_tex, p.xy).rgb * w.z;
	float lum = dot(t, vec3(0.299, 0.587, 0.114));
	vec3 base = haze * mix(1.0, lum / 0.33, detail); // 0.33: the texture's mean brightness
	// Sunlit haze on the upper slopes, as the old ridges had.
	float up = smoothstep(0.0, peak_height, world_pos.y);
	ALBEDO = mix(base, peak_light, 0.25 * up);
}
