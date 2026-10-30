// Spectators (tools/mpfb/build_crowd.py, scripts/stages/crowd.gd): every vertex's position
// and normal come from vertex-animation textures, one row per frame, the vertex's column in
// UV2 (x = column % 64, y = column / 64, in 64ths). Per instance (INSTANCE_CUSTOM): r = phase (seconds / 10), g = how excited the arena
// must be before this spectator cheers, b = talks rather than sits still, a = claps rather
// than cheers. The arena's excitement (0-1) is set by the stage every frame.
//
// Lighting is the crowd's own, not the engine's: a thousand people under the full lit shader
// cost about 2 ms a frame more than this (measured with a Metal System Trace on the Ring). It
// is matte: a sky/floor ambient, the stage's fill light (Crowd passes its direction and colour)
// and a soft spill from the ring that fades with distance. Calibrated against the lit shader
// at the fight camera (docs/graphics-plan.md).
shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float fps = 15.0;
uniform vec2 clip_idle = vec2(0.0, 1.0); // first row, rows
uniform vec2 clip_talk = vec2(0.0, 1.0);
uniform vec2 clip_cheer = vec2(0.0, 1.0);
uniform vec2 clip_clap = vec2(0.0, 1.0);
uniform float excitement = 0.0;
// Lighting (linear colour times energy).
uniform vec3 sky_light = vec3(0.3);
uniform vec3 ground_light = vec3(0.1);
uniform vec3 fill_dir = vec3(0.0, 1.0, 0.0); // towards the light, world space
uniform vec3 fill_light = vec3(0.0);
uniform vec3 ring_center = vec3(0.0, 3.0, 0.0);
uniform vec3 ring_light = vec3(0.0);
uniform float ring_reach = 10.0; // metres at which the spill is half as strong

varying vec3 world_normal;
varying vec3 world_pos;

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
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(pos, 1.0)).xyz;
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec3 light = mix(ground_light, sky_light, n.y * 0.5 + 0.5);
	light += fill_light * max(dot(n, fill_dir), 0.0);
	vec3 to_ring = ring_center - world_pos;
	float d = length(to_ring);
	light += ring_light * max(dot(n, to_ring / d), 0.0) * ring_reach * ring_reach / (ring_reach * ring_reach + d * d);
	ALBEDO = texture(albedo_tex, UV).rgb * COLOR.rgb * light;
}
