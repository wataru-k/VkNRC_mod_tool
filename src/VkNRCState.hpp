//
// Created by adamyuan on 2/23/24.
//

#pragma once
#ifndef VKNRC_VKNRCSTATE_HPP
#define VKNRC_VKNRCSTATE_HPP

#include <glm/glm.hpp>
#include <half.hpp>
#include <myvk/Buffer.hpp>
#include <myvk/Image.hpp>
#include <myvk/ImageView.hpp>
#include <optional>
#include <random>
#include <span>

class VkNRCState final : public myvk::DeviceObjectBase {
public:
	enum Method { kNone, kNRC, kCache };

private:
	inline static constexpr float kDefaultTrainProbability = 0.03f;
	inline static constexpr uint32_t kNNHiddenLayers = 5, kNNWidth = 64, kNNOutWidth = 3, kTrainBatchSize = 16384,
	                                 kTrainBatchCount = 4;
	inline static constexpr uint32_t kNNWeighCount = kNNWidth * kNNWidth * kNNHiddenLayers + kNNWidth * kNNOutWidth;

	myvk::Ptr<myvk::Queue> m_queue_ptr;
	// use_weights: weights used by actual renderer
	myvk::Ptr<myvk::Buffer> m_weights, m_use_weights, m_optimizer_state, m_optimizer_entries;
	myvk::Ptr<myvk::ImageView> m_accumulate_view;
	uint32_t m_seed{};
	uint32_t m_rng_seed;
	std::mt19937 m_rng;
	Method m_left_method{kNRC}, m_right_method{kNRC};
	bool m_accumulate{false};
	uint32_t m_accumulate_count{0};
	bool m_use_ema_weights{false};
	bool m_whiteout_diagnostic{false}, m_whiteout_guard{false};
	bool m_rtxgi_reference_lighting{false};
	float m_whiteout_luminance_threshold{100.0f};
	float m_train_probability{kDefaultTrainProbability};

	void initialize_weights(std::span<float, kNNWeighCount> weights);

public:
	inline VkNRCState(const myvk::Ptr<myvk::Queue> &queue_ptr, VkExtent2D extent,
	                  std::optional<uint32_t> rng_seed = std::nullopt)
	    : m_queue_ptr(queue_ptr), m_rng_seed(rng_seed.value_or(std::random_device{}())), m_rng(m_rng_seed) {
		ResetAccumulateImage(extent);
		ResetMLPBuffers();
	}
	inline ~VkNRCState() final = default;

	inline const auto &GetAccumulateImageView() const { return m_accumulate_view; }
	inline const auto &GetWeightBuffer() const { return m_weights; }
	inline const auto &GetUseWeightBuffer() const { return m_use_weights; }
	inline const auto &GetOptimizerEntryBuffer() const { return m_optimizer_entries; }
	inline const auto &GetOptimizerStateBuffer() const { return m_optimizer_state; }

	inline Method GetLeftMethod() const { return m_left_method; }
	inline Method GetRightMethod() const { return m_right_method; }
	inline bool IsAccumulate() const { return m_accumulate; }
	inline uint32_t GetAccumulateCount() const { return m_accumulate_count; }
	inline bool IsUseEMAWeights() const { return m_use_ema_weights; }
	inline bool IsWhiteoutDiagnostic() const { return m_whiteout_diagnostic; }
	inline bool IsWhiteoutGuard() const { return m_whiteout_guard; }
	inline bool IsRTXGIReferenceLighting() const { return m_rtxgi_reference_lighting; }
	inline float GetWhiteoutLuminanceThreshold() const { return m_whiteout_luminance_threshold; }
	inline float GetTrainProbability() const { return m_train_probability; }

	inline void SetLeftMethod(Method method) { m_left_method = method; }
	inline void SetRightMethod(Method method) { m_right_method = method; }
	inline void SetAccumulate(bool accumulate) {
		m_accumulate = accumulate;
		if (!accumulate)
			m_accumulate_count = 0;
	}
	inline void ResetAccumulateCount() { m_accumulate_count = 0; }
	inline void SetUseEMAWeights(bool use_ema_weights) { m_use_ema_weights = use_ema_weights; }
	inline void SetWhiteoutDiagnostic(bool enabled) { m_whiteout_diagnostic = enabled; }
	inline void SetWhiteoutGuard(bool enabled) { m_whiteout_guard = enabled; }
	inline void SetRTXGIReferenceLighting(bool enabled) { m_rtxgi_reference_lighting = enabled; }
	inline void SetWhiteoutLuminanceThreshold(float threshold) { m_whiteout_luminance_threshold = threshold; }
	inline void SetTrainProbability(float train_probability) { m_train_probability = train_probability; }

	inline uint32_t GetSeed() const { return m_seed; }
	inline uint32_t GetRNGSeed() const { return m_rng_seed; }

	inline void NextFrame() {
		if (m_accumulate)
			++m_accumulate_count;
		m_seed = std::uniform_int_distribution<uint32_t>{0}(m_rng);
	}

	void ResetAccumulateImage(VkExtent2D extent);
	void ResetMLPBuffers();

	inline const myvk::Ptr<myvk::Device> &GetDevicePtr() const { return m_queue_ptr->GetDevicePtr(); }
	static VkDeviceSize GetEvalRecordBufferSize(VkExtent2D extent);
	static VkDeviceSize GetBatchTrainRecordBufferSize();
	static constexpr uint32_t GetTrainBatchCount() { return kTrainBatchCount; }
	static constexpr uint32_t GetTrainBatchSize() { return kTrainBatchSize; }
	static constexpr uint32_t GetWeightCount() { return kNNWeighCount; }
	static constexpr float GetDefaultTrainProbability() { return kDefaultTrainProbability; }
};

#endif // VKNRC_VKNRCSTATE_HPP
