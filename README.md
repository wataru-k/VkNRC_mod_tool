# Vulkan Neural Radiance Caching

This fork is the development home for VkNRC modifications and compatibility
work used alongside `RTXGI_mod_tool`.

Implementation survey documents are available in [docs/survey](docs/survey/README.md).
See [docs/build-windows.md](docs/build-windows.md) for the verified Windows build procedure.
Whiteout investigation controls are documented in
[docs/whiteout-diagnostics.md](docs/whiteout-diagnostics.md).
RTXGI LivingRoom/Bistro asset porting is documented in
[docs/scene-porting.md](docs/scene-porting.md).

[![Windows MinGW](https://github.com/AdamYuan/VkNRC/actions/workflows/windows-mingw.yml/badge.svg)](https://github.com/AdamYuan/VkNRC/actions/workflows/windows-mingw.yml)
[![Windows MSVC](https://github.com/AdamYuan/VkNRC/actions/workflows/windows-msvc.yml/badge.svg)](https://github.com/AdamYuan/VkNRC/actions/workflows/windows-msvc.yml)

![](https://raw.githubusercontent.com/AdamYuan/VkNRC/master/screenshot/0.png)

Vulkan Implementation of NVIDIA's
paper [Real-time Neural Radiance Caching for Path Tracing](https://research.nvidia.com/publication/2021-06_real-time-neural-radiance-caching-path-tracing).

The Fully-Fused MLP is implemented with VK_NV_cooperative_matrix (the KHR one is too limited), and it has better
backpropagation performance than the author's [tiny-cuda-nn](https://github.com/NVlabs/tiny-cuda-nn).
