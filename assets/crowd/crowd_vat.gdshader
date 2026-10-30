// Spectators (tools/mpfb/build_crowd.py, scripts/stages/crowd.gd): every vertex's position
// and normal come from vertex-animation textures, one row per frame, the vertex's column in
// UV2 (x = column % 64, y = column / 64, in 64ths). Per instance (INSTANCE_CUSTOM): r = phase (seconds / 10), g = how excited the arena
// must be before this spectator cheers, b = talks rather than sits still, a = claps rather
// than cheers. The arena's excitement (0-1) is set by the stage every frame.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float fps = 15.0;
uniform vec2 clip_idle = vec2(0.0, 1.0); // first row, rows
uniform vec2 clip_talk = vec2(0.0, 1.0);
uniform vec2 clip_cheer = vec2(0.0, 1.0);
uniform vec2 clip_clap = vec2(0.0, 1.0);
uniform float excitement = 0.0;
uniform float roughness = 0.8;

vec3 fetch(sampler2D tex, int col, vec2 clip, float t) {
	float f = mod(t * fps, clip.y);
	int f0 = int(f);
	int f1 = (f0 + 1) % int(clip.y);
	vec3 a = texelFetch(tex, ivec2(col, int(clip.x) + f0), 0).rgb;
	vec3 b = texelFetch(tex, ivec2(col, int(clip.x) + f1), 0).rgb;
	return mix(a, b, fract(f));
}

void vertex() {
	// build_crowd.py vat_uv(); glTF stores V flipped (1 - v), so the high half reads back mirrored.
	int col = int(UV2.x * 64.0) + 64 * (63 - int(UV2.y * 64.0));
	vec4 c = INSTANCE_CUSTOM;
	float t = TIME + c.r * 10.0;
	vec2 calm = c.b > 0.5 ? clip_talk : clip_idle;
	vec2 loud = c.a > 0.5 ? clip_clap : clip_cheer;
	float w = smoothstep(c.g - 0.08, c.g + 0.08, excitement);
	// Most spectators are fully calm or fully loud: read one clip unless they're between.
	vec2 clip = w > 0.5 ? loud : calm;
	vec3 pos = fetch(vat_pos, col, clip, t);
	vec3 nrm = fetch(vat_nrm, col, clip, t);
	if (w > 0.001 && w < 0.999) {
		vec2 other = w > 0.5 ? calm : loud;
		float k = w > 0.5 ? 1.0 - w : w;
		pos = mix(pos, fetch(vat_pos, col, other, t), k);
		nrm = mix(nrm, fetch(vat_nrm, col, other, t), k);
	}
	VERTEX = pos;
	NORMAL = normalize(nrm);
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb * COLOR.rgb;
	ROUGHNESS = roughness;
}
