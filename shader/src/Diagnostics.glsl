#ifndef VKNRC_DIAGNOSTICS_GLSL
#define VKNRC_DIAGNOSTICS_GLSL

#define DIAG_HISTOGRAM_BINS 64u
#define DIAG_STAGE_WORDS 68u
#define DIAG_STAGE_TOTAL 0u
#define DIAG_STAGE_NONFINITE 1u
#define DIAG_STAGE_NEGATIVE 2u
#define DIAG_STAGE_MAX_BITS 3u
#define DIAG_STAGE_HISTOGRAM 4u

#define DIAG_BEFORE_BASE (0u * DIAG_STAGE_WORDS)
#define DIAG_RAW_BASE (1u * DIAG_STAGE_WORDS)
#define DIAG_FACTOR_BASE (2u * DIAG_STAGE_WORDS)
#define DIAG_CONTRIBUTION_BASE (3u * DIAG_STAGE_WORDS)
#define DIAG_AFTER_BASE (4u * DIAG_STAGE_WORDS)
#define DIAG_FINAL_BASE (5u * DIAG_STAGE_WORDS)
#define DIAG_PT_TARGET_BASE (6u * DIAG_STAGE_WORDS)
#define DIAG_BOOTSTRAP_TARGET_BASE (7u * DIAG_STAGE_WORDS)
#define DIAG_TRAIN_PREDICTION_BASE (8u * DIAG_STAGE_WORDS)
#define DIAG_LOSS_BASE (9u * DIAG_STAGE_WORDS)
#define DIAG_GRADIENT_BASE (10u * DIAG_STAGE_WORDS)
#define DIAG_UPDATE_BASE (11u * DIAG_STAGE_WORDS)
#define DIAG_WEIGHT_BASE (12u * DIAG_STAGE_WORDS)
#define DIAG_EMA_WEIGHT_BASE (13u * DIAG_STAGE_WORDS)
#define DIAG_BRDF_BASE (14u * DIAG_STAGE_WORDS)
#define DIAG_BRDF_PDF_BASE (15u * DIAG_STAGE_WORDS)
#define DIAG_BRDF_COSINE_BASE (16u * DIAG_STAGE_WORDS)
#define DIAG_BRDF_THROUGHPUT_BASE (17u * DIAG_STAGE_WORDS)
#define DIAG_BRDF_ROUGHNESS_BASE (18u * DIAG_STAGE_WORDS)
#define DIAG_STAGE_COUNT 19u
#define DIAG_BEFORE_WHITE (DIAG_STAGE_COUNT * DIAG_STAGE_WORDS)
#define DIAG_FINAL_WHITE (DIAG_BEFORE_WHITE + 1u)
#define DIAG_SCREEN_TOTAL (DIAG_BEFORE_WHITE + 2u)
#define DIAG_TRAIN_GENERATED (DIAG_BEFORE_WHITE + 3u)
#define DIAG_TRAIN_PT_ACCEPTED (DIAG_BEFORE_WHITE + 4u)
#define DIAG_TRAIN_BOOTSTRAP_ACCEPTED (DIAG_BEFORE_WHITE + 5u)
#define DIAG_TRAIN_INCOMPLETE_REJECTED (DIAG_BEFORE_WHITE + 6u)
#define DIAG_BRDF_STEP_TOTAL (DIAG_BEFORE_WHITE + 7u)
#define DIAG_BRDF_BELOW_HEMISPHERE (DIAG_BEFORE_WHITE + 8u)
#define DIAG_BRDF_BAD_PDF (DIAG_BEFORE_WHITE + 9u)
#define DIAG_BRDF_NONFINITE_THROUGHPUT (DIAG_BEFORE_WHITE + 10u)
#define DIAG_WORD_COUNT (DIAG_BEFORE_WHITE + 11u)

float DiagnosticLuminance(in const vec3 value) {
	return dot(vec3(0.212671, 0.715160, 0.072169), value);
}

void RecordDiagnosticStage(in const uint base, in const vec3 value) {
	atomicAdd(uFrameMetrics[base + DIAG_STAGE_TOTAL], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
	          gl_SemanticsAcquireRelease);
	if (any(isnan(value)) || any(isinf(value))) {
		atomicAdd(uFrameMetrics[base + DIAG_STAGE_NONFINITE], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
		          gl_SemanticsAcquireRelease);
		return;
	}
	if (any(lessThan(value, vec3(0))))
		atomicAdd(uFrameMetrics[base + DIAG_STAGE_NEGATIVE], 1u, gl_ScopeQueueFamily, gl_StorageSemanticsBuffer,
		          gl_SemanticsAcquireRelease);
	float luminance = max(DiagnosticLuminance(max(value, vec3(0))), 0.0);
	atomicMax(uFrameMetrics[base + DIAG_STAGE_MAX_BITS], floatBitsToUint(luminance), gl_ScopeQueueFamily,
	          gl_StorageSemanticsBuffer, gl_SemanticsAcquireRelease);
	uint bin = uint(clamp(floor(log2(max(luminance, exp2(-16.0)))) + 16.0, 0.0, 63.0));
	atomicAdd(uFrameMetrics[base + DIAG_STAGE_HISTOGRAM + bin], 1u, gl_ScopeQueueFamily,
	          gl_StorageSemanticsBuffer, gl_SemanticsAcquireRelease);
}

bool IsDiagnosticWhite(in const vec3 value) {
	if (any(isnan(value)) || any(isinf(value)))
		return false;
	return DiagnosticLuminance(value) >= 0.95 && max(value.r, max(value.g, value.b)) - min(value.r, min(value.g, value.b)) <= 0.05;
}

#endif
