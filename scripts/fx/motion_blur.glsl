#[compute]
#version 450

// Per-object motion blur (docs/motion-blur-plan.md, phase 1), after McGuire et al.,
// "A Reconstruction Filter for Plausible Motion Blur" (2012), with Jimenez's tweaks (2014).
// Four passes over one set of bindings, picked by `pass`:
//   0 VECTORS   each pixel's blur vector and distance, once (the gather reads them 13 times),
//               and the scene colour into a copy the gather reads (it writes the original)
//   1 TILES     the longest blur vector in each TILE x TILE tile
//   2 NEIGHBOUR the longest of each tile's 3x3 neighbourhood (a fast limb blurs past its edge)
//   3 GATHER    each pixel averaged along its neighbourhood's blur, weighted by depth and by
//               each sample's own motion, so fast limbs smear over the background but the
//               background never smears onto a still fighter
// A pixel's blur vector is its motion over the frame (Godot's motion vectors) with the
// camera's share scaled by `camera_weight`, times the exposure (shutter / frame time),
// capped at `max_blur` pixels.

#define TILE 16

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D color_copy;
layout(rg16f, set = 0, binding = 2) uniform restrict readonly image2D velocity_image;
layout(set = 0, binding = 3) uniform sampler2D depth_texture;
layout(rg16f, set = 0, binding = 4) uniform restrict image2D tile_max;
layout(rg16f, set = 0, binding = 5) uniform restrict image2D neighbour_max;
layout(rgba16f, set = 0, binding = 7) uniform restrict image2D vectors; // blur x, y, distance (m)

layout(set = 0, binding = 6, std140) uniform Params {
	mat4 inv_projection; // clip -> view, this frame
	mat4 reproject; // clip this frame -> clip last frame, for a still world (the camera's motion)
	vec4 size; // width, height, 1 / width, 1 / height
	vec4 blur; // exposure, max blur (px), camera weight, debug view (0 off, 1 motion, 2 object motion)
	vec4 misc; // samples, frame number, soft depth (m), velocity y sign
} params;

layout(push_constant, std430) uniform Pass {
	ivec4 pass_info; // x: pass
} pc;

// Godot's motion vectors: UV of the last frame minus UV of this one. Pixels per frame.
vec2 raw_motion(ivec2 p) {
	vec2 v = imageLoad(velocity_image, p).xy;
	return vec2(v.x, v.y * params.misc.w) * params.size.xy;
}

float depth_at(ivec2 p) {
	return texelFetch(depth_texture, p, 0).r;
}

// Distance in front of the camera (m), from the depth buffer.
float view_depth(float depth, vec2 uv) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view = params.inv_projection * clip;
	return -view.z / view.w;
}

// The camera's share of a pixel's motion (pixels per frame): where that point of a still
// world was on screen last frame.
vec2 camera_motion(ivec2 p, float depth) {
	vec2 uv = (vec2(p) + 0.5) * params.size.zw;
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 last = params.reproject * clip;
	vec2 last_uv = (last.xy / last.w) * 0.5 + 0.5;
	return (last_uv - uv) * params.size.xy;
}

// The blur vector of one pixel: its motion over the exposure, the camera's share weighted.
vec2 blur_vector(ivec2 p) {
	vec2 motion = raw_motion(p);
	vec2 camera = camera_motion(p, depth_at(p));
	vec2 v = (motion - camera + camera * params.blur.z) * params.blur.x;
	float len = length(v);
	return len > params.blur.y ? v * (params.blur.y / len) : v;
}

float cone(float dist, float radius) {
	return clamp(1.0 - dist / max(radius, 0.5), 0.0, 1.0);
}

float cylinder(float dist, float radius) {
	return 1.0 - smoothstep(0.95 * radius, 1.05 * radius + 0.5, dist);
}

// 1 when `a` is in front of `b`, fading over `soft` metres.
float in_front(float a, float b, float soft) {
	return clamp(1.0 - (a - b) / soft, 0.0, 1.0);
}

float noise(vec2 p) { // interleaved gradient noise
	return fract(52.9829189 * fract(dot(p + params.misc.y * 5.588238, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.size.xy);
	int pass_id = pc.pass_info.x;

	if (pass_id == 0) { // VECTORS and COPY
		if (any(greaterThanEqual(id, size))) return;
		vec2 uv = (vec2(id) + 0.5) * params.size.zw;
		imageStore(vectors, id, vec4(blur_vector(id), view_depth(depth_at(id), uv), 0.0));
		imageStore(color_copy, id, imageLoad(color_image, id));
		return;
	}
	if (pass_id == 1) { // TILES: one invocation per tile
		ivec2 tiles = (size + TILE - 1) / TILE;
		if (any(greaterThanEqual(id, tiles))) return;
		vec2 longest = vec2(0.0);
		for (int y = 0; y < TILE; y++) {
			for (int x = 0; x < TILE; x++) {
				ivec2 p = id * TILE + ivec2(x, y);
				if (any(greaterThanEqual(p, size))) continue;
				vec2 v = imageLoad(vectors, p).xy;
				if (dot(v, v) > dot(longest, longest)) longest = v;
			}
		}
		imageStore(tile_max, id, vec4(longest, 0.0, 0.0));
		return;
	}
	if (pass_id == 2) { // NEIGHBOUR
		ivec2 tiles = (size + TILE - 1) / TILE;
		if (any(greaterThanEqual(id, tiles))) return;
		vec2 longest = vec2(0.0);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec2 t = clamp(id + ivec2(x, y), ivec2(0), tiles - 1);
				vec2 v = imageLoad(tile_max, t).xy;
				if (dot(v, v) > dot(longest, longest)) longest = v;
			}
		}
		imageStore(neighbour_max, id, vec4(longest, 0.0, 0.0));
		return;
	}
	if (any(greaterThanEqual(id, size))) return;

	// GATHER
	if (params.blur.w > 0.5) { // debug: motion as colour (red right, green left, blue up/down)
		if (params.blur.w > 3.5) { // depth: white near, black far (0-10 m)
			float z = view_depth(depth_at(id), (vec2(id) + 0.5) * params.size.zw);
			imageStore(color_image, id, vec4(vec3(clamp(1.0 - z / 10.0, 0.0, 1.0)), 1.0));
			return;
		}
		vec2 v = params.blur.w > 2.5 ? camera_motion(id, depth_at(id)) : (params.blur.w > 1.5 ? blur_vector(id) : raw_motion(id) * params.blur.x);
		vec3 c = vec3(max(v.x, 0.0), max(-v.x, 0.0), abs(v.y)) / 24.0;
		imageStore(color_image, id, vec4(mix(imageLoad(color_copy, id).rgb * 0.25, c, clamp(length(v) / 3.0, 0.0, 1.0)), 1.0));
		return;
	}
	vec2 vn = imageLoad(neighbour_max, id / TILE).xy;
	float vn_len = length(vn);
	if (vn_len < 0.5) return; // nothing near moves: the pixel stays as rendered

	vec4 here = imageLoad(vectors, id);
	vec2 vc = here.xy;
	float rc = length(vc) * 0.5;
	float zc = here.z;
	vec4 center = imageLoad(color_copy, id);
	float soft = params.misc.z;

	int samples = int(params.misc.x);
	float jitter = noise(vec2(id)) - 0.5;
	float weight = 1.0 / max(rc, 0.5);
	vec3 total = center.rgb * weight;
	for (int i = 0; i < samples; i++) {
		if (i == (samples - 1) / 2) continue; // the centre is counted above
		float t = mix(-1.0, 1.0, (float(i) + jitter + 0.5) / float(samples));
		ivec2 s = clamp(ivec2(vec2(id) + 0.5 + vn * t * 0.5), ivec2(0), size - 1);
		float dist = abs(t) * vn_len * 0.5;
		vec4 there = imageLoad(vectors, s);
		float rs = length(there.xy) * 0.5;
		float zs = there.z;
		float front = in_front(zs, zc, soft); // the sample is in front of this pixel
		float back = in_front(zc, zs, soft); // this pixel is in front of the sample
		float w = front * cone(dist, rs) + back * cone(dist, rc) + cylinder(dist, rs) * cylinder(dist, rc) * 2.0;
		total += imageLoad(color_copy, s).rgb * w;
		weight += w;
	}
	imageStore(color_image, id, vec4(total / weight, center.a));
}
