# Windows build

## Verified environment

- Visual Studio 2022 with the Desktop development with C++ workload
- Windows SDK 10.0.26100.0
- Vulkan SDK 1.4.357.0
- CMake 3.30.3

The Vulkan SDK `Bin` directory must be on `PATH` so that CMake can find
`glslc.exe`. `VULKAN_SDK` should point to the SDK installation directory.

## Generate and build

Run these commands from the repository root:

```powershell
cmake -S . -B build-vs -G "Visual Studio 17 2022" -A x64
cmake --build build-vs --config Release --parallel
```

The executable is generated at `build-vs/Release/VkNRC.exe`.

VkNRC requires an OBJ scene path at runtime:

```powershell
.\build-vs\Release\VkNRC.exe <path-to-scene.obj>
```

The GPU and driver must support `VK_NV_cooperative_matrix` and the Vulkan
extensions enabled in `src/main.cpp`.
