// The crowd's vertex animation (crowd_vat.gdshaderinc) under the engine's lighting: for a
// handful of people on a stage whose light changes (the Courtyard's sunrise). The atlas is
// the colour; the instance colour tints it.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://assets/crowd/crowd_vat.gdshaderinc"

uniform float roughness = 0.8;

void vertex() {
	vat_vertex(VERTEX, NORMAL, UV2, INSTANCE_CUSTOM, TIME);
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb * COLOR.rgb;
	ROUGHNESS = roughness;
}
