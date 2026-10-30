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

#include "res://assets/crowd/crowd_vat.gdshaderinc"
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

void vertex() {
	vat_vertex(VERTEX, NORMAL, UV2, INSTANCE_CUSTOM, TIME);
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
