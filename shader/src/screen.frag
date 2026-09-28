#version 450
#extension GL_KHR_memory_scope_semantics : enable

layout(input_attachment_index = 0, binding = 0) uniform subpassInput uColor;
layout(binding = 1, rgba32f) uniform image2D uAccumulate;
layout(std430, binding = 2) buffer uuFrameMetrics { uint uFrameMetrics[]; };
layout(binding = 3, rgba32f) readonly uniform image2D uBeforeResolve;
layout(binding = 4, rgba32f) readonly uniform image2D uResolvedPreOverlay;
#include "Diagnostics.glsl"

layout(location = 0) out vec4 oScreen;

layout(push_constant) uniform uuPushConstant { uint uIsAccumulate, uAccumulateCount, uFrameMetricsEnabled; };

vec3 ToneMapFilmic_Hejl2015(in const vec3 hdr, in const float white_pt) {
	vec4 vh = vec4(hdr, white_pt);
	vec4 va = (1.425 * vh) + 0.05;
	vec4 vf = (vh * va + 0.004) / ((vh * (va + 0.55) + 0.0491)) - 0.0821;
	return vf.rgb / vf.w;
}

vec3 EncodeScreen(in const vec3 hdr) {
	return pow(max(ToneMapFilmic_Hejl2015(max(hdr, vec3(0)), 3.2), vec3(0)), vec3(1 / 2.2));
}

void main() {
	vec3 color = subpassLoad(uColor).rgb;

	ivec2 coord = ivec2(gl_FragCoord.xy);
	if (uIsAccumulate != 0) {
		if (uAccumulateCount != 0) {
			color += imageLoad(uAccumulate, coord).rgb * float(uAccumulateCount);
			color /= float(uAccumulateCount + 1);
		}
		imageStore(uAccumulate, coord, vec4(color, 0));
	}

	vec3 screen = EncodeScreen(color);
	vec3 before_screen = EncodeScreen(imageLoad(uBeforeResolve, coord).rgb);
	vec3 pre_overlay_screen = EncodeScreen(imageLoad(uResolvedPreOverlay, coord).rgb);
	if (uFrameMetricsEnabled != 0) {
		RecordDiagnosticStage(DIAG_BEFORE_BASE, imageLoad(uBeforeResolve, coord).rgb);
		RecordDiagnosticStage(DIAG_FINAL_BASE, pre_overlay_screen);
		atomicAdd(uFrameMetrics[DIAG_SCREEN_TOTAL], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
		          gl_SemanticsAcquireRelease);
		if (IsDiagnosticWhite(before_screen))
			atomicAdd(uFrameMetrics[DIAG_BEFORE_WHITE], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
			          gl_SemanticsAcquireRelease);
		if (IsDiagnosticWhite(pre_overlay_screen))
			atomicAdd(uFrameMetrics[DIAG_FINAL_WHITE], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
			          gl_SemanticsAcquireRelease);
	}
	oScreen = vec4(screen, 1.0);
}
