#include <myvk/FrameManager.hpp>
#include <myvk/GLFWHelper.hpp>
#include <myvk/ImGuiHelper.hpp>

#include <spdlog/spdlog.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <bit>
#include <algorithm>
#include <limits>
#include <optional>

#include "rg/NRCRenderGraph.hpp"

constexpr uint32_t kFrameCount = 3, kWidth = 1280, kHeight = 720;

int main(int argc, char **argv) {
	if (argc < 2) {
		spdlog::error("No OBJ file");
		return EXIT_FAILURE;
	}
	const char *scene_path = argv[1];
	bool command_line_whiteout_diagnostic = false, command_line_whiteout_guard = false;
	bool command_line_rtxgi_reference_lighting = false;
	float command_line_whiteout_threshold = 100.0f;
	uint64_t command_line_frame_limit = 0;
	std::optional<uint32_t> command_line_seed;
	std::optional<glm::vec3> command_line_camera_position;
	std::optional<float> command_line_camera_yaw, command_line_camera_pitch, command_line_camera_fov;
	bool command_line_validate_scene_only = false;
	const auto parse_float = [](const char *value, const char *option) {
		char *end = nullptr;
		float parsed = std::strtof(value, &end);
		if (end == value || *end != '\0' || !std::isfinite(parsed)) {
			spdlog::error("Invalid {} value: {}", option, value);
			std::exit(EXIT_FAILURE);
		}
		return parsed;
	};
	for (int i = 2; i < argc; ++i) {
		if (std::strcmp(argv[i], "--whiteout-diagnostic") == 0) {
			command_line_whiteout_diagnostic = true;
		} else if (std::strcmp(argv[i], "--validate-scene-only") == 0) {
			command_line_validate_scene_only = true;
		} else if (std::strcmp(argv[i], "--whiteout-guard") == 0) {
			command_line_whiteout_guard = true;
		} else if (std::strcmp(argv[i], "--rtxgi-reference-lighting") == 0) {
			command_line_rtxgi_reference_lighting = true;
		} else if (std::strcmp(argv[i], "--whiteout-threshold") == 0 && i + 1 < argc) {
			char *end = nullptr;
			command_line_whiteout_threshold = std::strtof(argv[++i], &end);
			if (end == argv[i] || *end != '\0' || !std::isfinite(command_line_whiteout_threshold) ||
			    command_line_whiteout_threshold <= 0.0f) {
				spdlog::error("Invalid --whiteout-threshold value: {}", argv[i]);
				return EXIT_FAILURE;
			}
		} else if (std::strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
			char *end = nullptr;
			command_line_frame_limit = std::strtoull(argv[++i], &end, 10);
			if (end == argv[i] || *end != '\0' || command_line_frame_limit == 0) {
				spdlog::error("Invalid --frames value: {}", argv[i]);
				return EXIT_FAILURE;
			}
		} else if (std::strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
			char *end = nullptr;
			uint64_t parsed_seed = std::strtoull(argv[++i], &end, 10);
			if (end == argv[i] || *end != '\0' || parsed_seed > std::numeric_limits<uint32_t>::max()) {
				spdlog::error("Invalid --seed value: {}", argv[i]);
				return EXIT_FAILURE;
			}
			command_line_seed = static_cast<uint32_t>(parsed_seed);
		} else if (std::strcmp(argv[i], "--camera-position") == 0 && i + 3 < argc) {
			command_line_camera_position = glm::vec3{parse_float(argv[++i], "--camera-position"),
			                                                parse_float(argv[++i], "--camera-position"),
			                                                parse_float(argv[++i], "--camera-position")};
		} else if (std::strcmp(argv[i], "--camera-yaw") == 0 && i + 1 < argc) {
			command_line_camera_yaw = parse_float(argv[++i], "--camera-yaw");
		} else if (std::strcmp(argv[i], "--camera-pitch") == 0 && i + 1 < argc) {
			command_line_camera_pitch = parse_float(argv[++i], "--camera-pitch");
		} else if (std::strcmp(argv[i], "--camera-fov") == 0 && i + 1 < argc) {
			command_line_camera_fov = parse_float(argv[++i], "--camera-fov");
			if (*command_line_camera_fov <= 0.0f || *command_line_camera_fov >= glm::pi<float>()) {
				spdlog::error("--camera-fov must be between 0 and pi radians");
				return EXIT_FAILURE;
			}
		} else {
			spdlog::error("Unknown or incomplete option: {}", argv[i]);
			return EXIT_FAILURE;
		}
	}
	// Scene scene = Scene::LoadOBJShapeInstanceSAH(argv[0], 7); // at most 128 instances
	Scene scene = Scene::LoadOBJSingleInstance(scene_path);
	if (scene.Empty())
		return EXIT_FAILURE;
	spdlog::info("Loaded {} Vertices, {} Normals, {} Tangents, {} Texcoords, {} Materials, {} Instances",
	             scene.GetVertices().size(), scene.GetNormals().size() - 1,
	             std::ranges::count_if(scene.GetTangents(), [](const glm::vec4 &tangent) { return tangent.w != 0.0f; }),
	             scene.GetTexcoords().size(), scene.GetMaterials().size(), scene.GetInstances().size());
	if (command_line_validate_scene_only) {
		spdlog::info("Scene validation completed without creating a Vulkan device");
		return EXIT_SUCCESS;
	}

	GLFWwindow *window = myvk::GLFWCreateWindow("VkNRC", kWidth, kHeight, true);

	auto instance = myvk::Instance::CreateWithGlfwExtensions();
	myvk::Ptr<myvk::Queue> generic_queue, compute_queue;
	myvk::Ptr<myvk::PresentQueue> present_queue;
	myvk::Ptr<myvk::PhysicalDevice> physical_device;
	for (const auto &candidate_physical_device : myvk::PhysicalDevice::Fetch(instance)) {
		if (candidate_physical_device->GetExtensionSupport(VK_NV_COOPERATIVE_MATRIX_EXTENSION_NAME)) {
			physical_device = candidate_physical_device;
			break;
		}
	}
	if (physical_device == nullptr) {
		spdlog::error("No Device Supporting VK_NV_cooperative_matrix Found");
		return -1;
	}
	spdlog::info("Physical Device: {}", physical_device->GetProperties().vk10.deviceName);
	auto features = physical_device->GetDefaultFeatures();
	features.vk11.storageBuffer16BitAccess = VK_TRUE;
	features.vk12.bufferDeviceAddress = VK_TRUE;
	features.vk12.hostQueryReset = VK_TRUE;
	features.vk12.shaderFloat16 = VK_TRUE;
	features.vk12.vulkanMemoryModel = VK_TRUE;
	features.vk12.vulkanMemoryModelDeviceScope = VK_TRUE;
	features.vk13.computeFullSubgroups = VK_TRUE;
	features.vk13.subgroupSizeControl = VK_TRUE;
	VkPhysicalDeviceShaderAtomicFloatFeaturesEXT atomic_float_features = {
	    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT,
	    .shaderBufferFloat32AtomicAdd = VK_TRUE};
	VkPhysicalDeviceCooperativeMatrixFeaturesNV cooperative_matrix_features = {
	    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_COOPERATIVE_MATRIX_FEATURES_NV,
	    .pNext = &atomic_float_features,
	    .cooperativeMatrix = VK_TRUE,
	    .cooperativeMatrixRobustBufferAccess = VK_FALSE};
	VkPhysicalDeviceRayQueryFeaturesKHR ray_query_features = {
	    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR,
	    .pNext = &cooperative_matrix_features,
	    .rayQuery = VK_TRUE};
	VkPhysicalDeviceAccelerationStructureFeaturesKHR accel_features = {
	    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
	    .pNext = &ray_query_features,
	    .accelerationStructure = VK_TRUE};
	features.vk13.pNext = &accel_features;
	auto device = myvk::Device::Create(
	    physical_device,
	    myvk::GenericPresentQueueSelector{&generic_queue, myvk::Surface::Create(instance, window), &present_queue},
	    features,
	    {VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,
	     VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME, VK_KHR_RAY_QUERY_EXTENSION_NAME,
	     VK_NV_COOPERATIVE_MATRIX_EXTENSION_NAME, VK_EXT_SHADER_ATOMIC_FLOAT_EXTENSION_NAME});
	myvk::ImGuiInit(window, myvk::CommandPool::Create(generic_queue));

	auto camera = myvk::MakePtr<Camera>();
	if (command_line_camera_position)
		camera->position = *command_line_camera_position;
	if (command_line_camera_yaw)
		camera->yaw = *command_line_camera_yaw;
	if (command_line_camera_pitch)
		camera->pitch = *command_line_camera_pitch;
	if (command_line_camera_fov)
		camera->fov = *command_line_camera_fov;
	spdlog::info("Camera: position=({}, {}, {}), yaw={}, pitch={}, fov={}", camera->position.x, camera->position.y,
	             camera->position.z, camera->yaw, camera->pitch, camera->fov);
	Camera::Control cam_control{.sensitivity = 0.005f, .speed = 0.5f, .prev_cursor_pos = {}};

	auto vk_scene = myvk::MakePtr<VkScene>(generic_queue, scene);
	auto vk_scene_blas = myvk::MakePtr<VkSceneBLAS>(vk_scene);
	auto vk_scene_tlas = myvk::MakePtr<VkSceneTLAS>(vk_scene_blas);
	auto vk_nrc_state = myvk::MakePtr<VkNRCState>(generic_queue, VkExtent2D{kWidth, kHeight}, command_line_seed);
	vk_nrc_state->SetWhiteoutDiagnostic(command_line_whiteout_diagnostic);
	vk_nrc_state->SetWhiteoutGuard(command_line_whiteout_guard);
	vk_nrc_state->SetRTXGIReferenceLighting(command_line_rtxgi_reference_lighting);
	vk_nrc_state->SetWhiteoutLuminanceThreshold(command_line_whiteout_threshold);
	spdlog::info("Whiteout diagnostic: {}, guard: {}, luminance threshold: {}",
	             command_line_whiteout_diagnostic, command_line_whiteout_guard, command_line_whiteout_threshold);
	spdlog::info("RNG seed: {}", vk_nrc_state->GetRNGSeed());
	spdlog::info("RTXGI reference lighting: {}", command_line_rtxgi_reference_lighting);

	auto frame_manager = myvk::FrameManager::Create(generic_queue, present_queue, false, kFrameCount);
	frame_manager->SetResizeFunc([&](VkExtent2D extent) {
		vk_nrc_state->ResetAccumulateImage(extent);
		vk_nrc_state->ResetAccumulateCount();
	});
	std::array<myvk::Ptr<rg::NRCRenderGraph>, kFrameCount> render_graphs;
	for (auto &rg : render_graphs)
		rg = myvk::MakePtr<rg::NRCRenderGraph>(frame_manager, vk_scene_tlas, vk_nrc_state, camera);

	bool view_accumulate = vk_nrc_state->IsAccumulate();
	int view_left_method = static_cast<int>(vk_nrc_state->GetLeftMethod());
	int view_right_method = static_cast<int>(vk_nrc_state->GetRightMethod());
	bool nrc_use_ema = vk_nrc_state->IsUseEMAWeights(), nrc_lock = false, nrc_train_one_frame = false;
	bool nrc_whiteout_diagnostic = vk_nrc_state->IsWhiteoutDiagnostic();
	bool nrc_whiteout_guard = vk_nrc_state->IsWhiteoutGuard();
	bool rtxgi_reference_lighting = vk_nrc_state->IsRTXGIReferenceLighting();
	float nrc_whiteout_luminance_threshold = vk_nrc_state->GetWhiteoutLuminanceThreshold();

	uint64_t rendered_frame_count = 0;
	double prev_time = glfwGetTime();
	while (!glfwWindowShouldClose(window)) {
		double delta;
		{
			double cur_time = glfwGetTime();
			delta = cur_time - prev_time;
			prev_time = cur_time;
		}
		glfwPollEvents();

		nrc_train_one_frame = false;

		myvk::ImGuiNewFrame();
		ImGui::Begin("Panel");
		ImGui::Text("FPS %.1f", ImGui::GetIO().Framerate);
		if (ImGui::CollapsingHeader("View")) {
			if (ImGui::Checkbox("RTXGI Reference Lighting", &rtxgi_reference_lighting)) {
				vk_nrc_state->SetRTXGIReferenceLighting(rtxgi_reference_lighting);
				vk_nrc_state->ResetAccumulateCount();
			}
			if (ImGui::Checkbox("Accumulate", &view_accumulate))
				vk_nrc_state->SetAccumulate(view_accumulate);
			if (vk_nrc_state->IsAccumulate()) {
				ImGui::SameLine();
				ImGui::Text("SPP %d", vk_nrc_state->GetAccumulateCount());
			}
			constexpr const char *kViewTypeComboStr = "None\0NRC\0Cache\0";
			if (ImGui::Combo("Left", &view_left_method, kViewTypeComboStr)) {
				vk_nrc_state->SetLeftMethod(static_cast<VkNRCState::Method>(view_left_method));
				vk_nrc_state->ResetAccumulateCount();
			}
			if (ImGui::Combo("Right", &view_right_method, kViewTypeComboStr)) {
				vk_nrc_state->SetRightMethod(static_cast<VkNRCState::Method>(view_right_method));
				vk_nrc_state->ResetAccumulateCount();
			}
		}
		if (ImGui::CollapsingHeader("NRC")) {
			if (ImGui::Checkbox("Use EMA", &nrc_use_ema)) {
				vk_nrc_state->SetUseEMAWeights(nrc_use_ema);
				vk_nrc_state->ResetAccumulateCount();
			}
			if (ImGui::Checkbox("Lock", &nrc_lock))
				vk_nrc_state->ResetAccumulateCount();
			if (nrc_lock) {
				ImGui::SameLine();
				if (ImGui::Button("Train 1-Frame")) {
					vk_nrc_state->ResetAccumulateCount();
					nrc_train_one_frame = true;
				}
			}
			if (ImGui::Button("Re-Train")) {
				vk_nrc_state->ResetAccumulateCount();
				vk_nrc_state->ResetMLPBuffers();
			}
			if (ImGui::Checkbox("Whiteout Diagnostic", &nrc_whiteout_diagnostic)) {
				vk_nrc_state->SetWhiteoutDiagnostic(nrc_whiteout_diagnostic);
				vk_nrc_state->ResetAccumulateCount();
			}
			if (ImGui::Checkbox("Experimental Whiteout Guard", &nrc_whiteout_guard)) {
				vk_nrc_state->SetWhiteoutGuard(nrc_whiteout_guard);
				vk_nrc_state->ResetAccumulateCount();
			}
			if (ImGui::SliderFloat("Whiteout Luminance", &nrc_whiteout_luminance_threshold, 1.0f, 1000.0f,
			                       "%.1f", ImGuiSliderFlags_Logarithmic)) {
				vk_nrc_state->SetWhiteoutLuminanceThreshold(nrc_whiteout_luminance_threshold);
				vk_nrc_state->ResetAccumulateCount();
			}
		}
		ImGui::End();
		ImGui::Render();

		if (camera->DragControl(window, &cam_control, delta))
			vk_nrc_state->ResetAccumulateCount();

		if (nrc_lock && !nrc_train_one_frame)
			vk_nrc_state->SetTrainProbability(0.0f);
		else
			vk_nrc_state->SetTrainProbability(VkNRCState::GetDefaultTrainProbability());

		if (frame_manager->NewFrame()) {
			const auto &command_buffer = frame_manager->GetCurrentCommandBuffer();
			auto &render_graph = render_graphs[frame_manager->GetCurrentFrame()];

			command_buffer->Begin(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
			render_graph->SetCanvasSize(frame_manager->GetExtent());
			render_graph->CmdExecute(command_buffer);
			command_buffer->End();

			frame_manager->Render();
			++rendered_frame_count;
			if (command_line_frame_limit != 0 && rendered_frame_count >= command_line_frame_limit) {
				spdlog::info("Completed requested {} rendered frames", rendered_frame_count);
				glfwSetWindowShouldClose(window, GLFW_TRUE);
			}
		}

		vk_nrc_state->NextFrame();
	}

	frame_manager->WaitIdle();
	uint64_t invalid_count = 0, overbright_count = 0, evaluated_count = 0;
	float max_luminance = 0.0f;
	for (const auto &render_graph : render_graphs) {
		auto counters = render_graph->GetWhiteoutCounters();
		invalid_count += counters.invalid_count;
		overbright_count += counters.overbright_count;
		evaluated_count += counters.evaluated_count;
		max_luminance = std::max(max_luminance, std::bit_cast<float>(counters.max_luminance_bits));
	}
	spdlog::info("Whiteout counters: evaluated={}, nonfinite={}, over-threshold={}, max-luminance={}",
	             evaluated_count, invalid_count, overbright_count, max_luminance);
	glfwTerminate();
	return 0;
}
