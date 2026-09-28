//
// Created by adamyuan on 2/22/24.
//

#pragma once
#ifndef VKNRC_RG_NRCRENDERGRAPH_HPP
#define VKNRC_RG_NRCRENDERGRAPH_HPP

#include "../Camera.hpp"
#include "../VkNRCState.hpp"
#include "../VkSceneTLAS.hpp"
#include "NRCResources.hpp"
#include "SceneResources.hpp"

#include <myvk_rg/RenderGraph.hpp>
#include <array>

namespace rg {

class NRCRenderGraph final : public myvk_rg::RenderGraphBase {
public:
	struct WhiteoutCounters {
		uint32_t invalid_count, overbright_count, max_luminance_bits, evaluated_count;
	};
	static constexpr uint32_t kDiagnosticHistogramBins = 64;
	struct DiagnosticStageMetrics {
		uint32_t total, nonfinite, negative, max_luminance_bits;
		std::array<uint32_t, kDiagnosticHistogramBins> histogram;
	};
	struct FrameMetrics {
		std::array<DiagnosticStageMetrics, 19> stages;
		uint32_t before_white, final_white, screen_total;
		uint32_t train_generated, train_pt_accepted, train_bootstrap_accepted, train_incomplete_rejected;
		uint32_t brdf_step_total, brdf_below_hemisphere, brdf_bad_pdf, brdf_nonfinite_throughput;
	};
	static_assert(sizeof(FrameMetrics) == (19 * (4 + kDiagnosticHistogramBins) + 11) * sizeof(uint32_t));

private:
	myvk::Ptr<VkSceneTLAS> m_scene_tlas_ptr;
	myvk::Ptr<VkScene> m_scene_ptr;
	myvk::Ptr<VkNRCState> m_nrc_state_ptr;
	mutable bool m_whiteout_counters_initialized{false};

	SceneResources create_scene_resources();
	NRCResources create_nrc_resources();

public:
	explicit NRCRenderGraph(const myvk::Ptr<myvk::FrameManager> &frame_manager,
	                        const myvk::Ptr<VkSceneTLAS> &scene_tlas_ptr, const myvk::Ptr<VkNRCState> &nrc_state_ptr,
	                        const myvk::Ptr<Camera> &camera_ptr);
	~NRCRenderGraph() final = default;
	void PreExecute() const final;
	WhiteoutCounters GetWhiteoutCounters() const;
	FrameMetrics GetFrameMetrics() const;
};

} // namespace rg

#endif
