// Full-screen fight effects (scripts/fx/fight_fx.gd ScreenFx), drawn over the 3D view:
// - impact: one or two frames of a high-contrast, near-monochrome frame on super finishers,
//   K.O.s and heavy counter hits (the classic "impact frame"), tinted by `impact_tint`;
// - a heat-distortion shockwave: a thin ring around `shock_center` (UV) that grows over
//   0.3 s and bends the picture outward as it passes;
// - darken: during a super's freeze everything darkens except a soft ellipse around the
//   fighter starting it (`focus_center`, UV), so the background drops away.
// Every effect is 0 when idle, so the shader costs a texture read per pixel and nothing else.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float impact = 0.0;
uniform vec3 impact_tint : source_color = vec3(1.0, 0.95, 0.85);
uniform vec2 shock_center = vec2(0.5);
uniform float shock_radius = 0.0; // in screen heights
uniform float shock_strength = 0.0;
uniform float darken = 0.0;
uniform vec2 focus_center = vec2(0.5);
uniform float aspect = 1.7778;

void fragment() {
	vec2 uv = SCREEN_UV;
	if (shock_strength > 0.0) {
		vec2 d = (uv - shock_center) * vec2(aspect, 1.0);
		float r = length(d);
		float band = 1.0 - smoothstep(0.0, 0.045, abs(r - shock_radius));
		uv -= normalize(d + 1e-5) / vec2(aspect, 1.0) * band * shock_strength * 0.025;
	}
	vec3 c = texture(screen_tex, uv).rgb;
	if (darken > 0.0) {
		vec2 d = (SCREEN_UV - focus_center) * vec2(aspect, 1.0) * vec2(1.0, 0.75);
		float keep = 1.0 - smoothstep(0.18, 0.42, length(d));
		c *= mix(1.0 - 0.62 * darken, 1.0, keep);
		c = mix(c, c * vec3(0.85, 0.88, 1.05), darken * (1.0 - keep)); // a cooler background
	}
	if (impact > 0.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		float hard = smoothstep(0.32, 0.5, l);
		vec3 frame = mix(vec3(0.03, 0.02, 0.04), impact_tint, hard);
		c = mix(c, frame, impact * 0.85);
	}
	COLOR = vec4(c, 1.0);
}
