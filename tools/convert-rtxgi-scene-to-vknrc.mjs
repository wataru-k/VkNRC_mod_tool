#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

const args = process.argv.slice(2);
let texconvPath = null;
const texconvIndex = args.indexOf("--texconv");
if (texconvIndex !== -1) {
  if (!args[texconvIndex + 1]) fail("--texconv requires an executable path");
  texconvPath = path.resolve(args[texconvIndex + 1]);
  args.splice(texconvIndex, 2);
}
if (args.length !== 2)
  fail("usage: node tools/convert-rtxgi-scene-to-vknrc.mjs <scene.json> <output.obj> [--texconv <texconv.exe>]");

const scenePath = path.resolve(args[0]);
const outputPath = path.resolve(args[1]);
const outputDir = path.dirname(outputPath);
const outputStem = path.parse(outputPath).name;
const mtlPath = path.join(outputDir, `${outputStem}.mtl`);
const manifestPath = path.join(outputDir, `${outputStem}.vknrc.json`);
const textureDir = path.join(outputDir, "textures");
fs.mkdirSync(textureDir, { recursive: true });

const scene = JSON.parse(fs.readFileSync(scenePath, "utf8"));
const componentBytes = new Map([[5121, 1], [5122, 2], [5123, 2], [5125, 4], [5126, 4]]);
const componentCounts = new Map([["SCALAR", 1], ["VEC2", 2], ["VEC3", 3], ["VEC4", 4]]);

function loadModel(uri) {
  const gltfPath = path.resolve(path.dirname(scenePath), uri);
  const gltf = JSON.parse(fs.readFileSync(gltfPath, "utf8"));
  if (!Array.isArray(gltf.buffers) || gltf.buffers.length !== 1)
    fail(`${gltfPath}: only one external buffer is supported`);
  const bufferUri = gltf.buffers[0].uri;
  if (!bufferUri || bufferUri.startsWith("data:"))
    fail(`${gltfPath}: an external binary buffer is required`);
  return {
    gltfPath,
    baseDir: path.dirname(gltfPath),
    gltf,
    binary: fs.readFileSync(path.resolve(path.dirname(gltfPath), decodeURIComponent(bufferUri))),
  };
}

const models = scene.models.map(loadModel);

function readComponent(ctx, offset, type, normalized) {
  let value;
  switch (type) {
    case 5121: value = ctx.binary.readUInt8(offset); break;
    case 5122: value = ctx.binary.readInt16LE(offset); break;
    case 5123: value = ctx.binary.readUInt16LE(offset); break;
    case 5125: value = ctx.binary.readUInt32LE(offset); break;
    case 5126: return ctx.binary.readFloatLE(offset);
    default: fail(`unsupported component type ${type}`);
  }
  if (!normalized) return value;
  if (type === 5121) return value / 255;
  if (type === 5122) return Math.max(value / 32767, -1);
  if (type === 5123) return value / 65535;
  if (type === 5125) return value / 4294967295;
  return value;
}

function accessorReader(ctx, accessorIndex) {
  const accessor = ctx.gltf.accessors[accessorIndex];
  if (!accessor || accessor.sparse) fail(`unsupported accessor ${accessorIndex} in ${ctx.gltfPath}`);
  const view = ctx.gltf.bufferViews[accessor.bufferView];
  const bytes = componentBytes.get(accessor.componentType);
  const count = componentCounts.get(accessor.type);
  if (!view || !bytes || !count) fail(`unsupported accessor layout ${accessorIndex} in ${ctx.gltfPath}`);
  const base = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  const stride = view.byteStride ?? bytes * count;
  return {
    count: accessor.count,
    get(index) {
      const result = new Array(count);
      const start = base + index * stride;
      for (let c = 0; c < count; ++c)
        result[c] = readComponent(ctx, start + c * bytes, accessor.componentType, accessor.normalized === true);
      return result;
    },
  };
}

function identity() { return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; }
function multiply(a, b) {
  const out = new Array(16).fill(0);
  for (let col = 0; col < 4; ++col)
    for (let row = 0; row < 4; ++row)
      for (let k = 0; k < 4; ++k)
        out[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k];
  return out;
}

function trsMatrix(translation = [0, 0, 0], rotation = [0, 0, 0, 1], scale = [1, 1, 1]) {
  let [x, y, z, w] = rotation;
  if (x * x + y * y + z * z + w * w < 1e-12) [x, y, z, w] = [0, 0, 0, 1];
  const [sx, sy, sz] = scale;
  const [tx, ty, tz] = translation;
  return [
    (1 - 2 * y * y - 2 * z * z) * sx, (2 * x * y + 2 * z * w) * sx,
    (2 * x * z - 2 * y * w) * sx, 0,
    (2 * x * y - 2 * z * w) * sy, (1 - 2 * x * x - 2 * z * z) * sy,
    (2 * y * z + 2 * x * w) * sy, 0,
    (2 * x * z + 2 * y * w) * sz, (2 * y * z - 2 * x * w) * sz,
    (1 - 2 * x * x - 2 * y * y) * sz, 0,
    tx, ty, tz, 1,
  ];
}

function nodeMatrix(node) {
  return node.matrix ?? trsMatrix(node.translation, node.rotation, node.scale);
}

function graphMatrix(entry) {
  const s = entry.scaling ?? 1;
  const scale = Array.isArray(s) ? s : [s, s, s];
  return trsMatrix(entry.translation, entry.rotation, scale);
}

function transformPoint(m, p) {
  return [
    m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
    m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
    m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
  ];
}

function textureSource(ctx, textureInfo) {
  if (!textureInfo) return null;
  const texture = ctx.gltf.textures?.[textureInfo.index];
  if (!texture) return null;
  const sourceIndex = texture.extensions?.MSFT_texture_dds?.source ?? texture.source;
  const image = ctx.gltf.images?.[sourceIndex];
  if (!image?.uri) return null;
  return path.resolve(ctx.baseDir, decodeURIComponent(image.uri));
}

const copiedTextures = new Map();
function copyTexture(source, modelIndex) {
  if (!source) return null;
  if (copiedTextures.has(source)) return copiedTextures.get(source);
  const extension = path.extname(source).toLowerCase();
  const outputExtension = extension === ".dds" ? ".png" : extension;
  if (![".jpg", ".jpeg", ".png", ".tga", ".bmp", ".dds"].includes(extension))
    fail(`unsupported texture ${source}`);
  const targetName = `model_${modelIndex}_${copiedTextures.size}${outputExtension}`;
  const target = path.join(textureDir, targetName);
  if (extension === ".dds") {
    if (!texconvPath || !fs.existsSync(texconvPath))
      fail(`DDS texture requires --texconv <texconv.exe>: ${source}`);
    const temporaryDir = path.join(textureDir, `_texconv_${copiedTextures.size}`);
    fs.mkdirSync(temporaryDir, { recursive: true });
    const result = spawnSync(texconvPath, ["-y", "-ft", "png", "-o", temporaryDir, source],
      { encoding: "utf8", windowsHide: true });
    if (result.status !== 0)
      fail(`texconv failed for ${source}: ${result.stderr || result.stdout}`);
    const converted = fs.readdirSync(temporaryDir).find((name) => path.extname(name).toLowerCase() === ".png");
    if (!converted) fail(`texconv produced no PNG for ${source}`);
    fs.renameSync(path.join(temporaryDir, converted), target);
    fs.rmSync(temporaryDir, { recursive: true, force: true });
  } else {
    fs.copyFileSync(source, target);
  }
  const relative = path.relative(outputDir, target).replaceAll("\\", "/");
  copiedTextures.set(source, relative);
  return relative;
}

const materialBases = [];
let materialCount = 0;
let mtl = "# Materials generated from an RTXGI scene manifest for VkNRC.\n";
for (let modelIndex = 0; modelIndex < models.length; ++modelIndex) {
  const ctx = models[modelIndex];
  const materials = ctx.gltf.materials?.length ? ctx.gltf.materials : [{}];
  materialBases[modelIndex] = materialCount;
  for (let localIndex = 0; localIndex < materials.length; ++localIndex) {
    const material = materials[localIndex];
    const specGloss = material.extensions?.KHR_materials_pbrSpecularGlossiness;
    const pbr = material.pbrMetallicRoughness;
    const diffuse = specGloss?.diffuseFactor?.slice(0, 3) ?? pbr?.baseColorFactor?.slice(0, 3) ?? [1, 1, 1];
    const specular = specGloss?.specularFactor ?? [0.04, 0.04, 0.04];
    const emission = material.emissiveFactor ?? [0, 0, 0];
    const roughness = Math.max(0.001, specGloss ? 1 - (specGloss.glossinessFactor ?? 1) : (pbr?.roughnessFactor ?? 1));
    const diffuseMap = copyTexture(textureSource(ctx, specGloss?.diffuseTexture ?? pbr?.baseColorTexture), modelIndex);
    const specularMap = copyTexture(textureSource(ctx, specGloss?.specularGlossinessTexture), modelIndex);
    const emissionMap = copyTexture(textureSource(ctx, material.emissiveTexture), modelIndex);
    mtl += `newmtl material_${materialCount}\nKd ${diffuse.join(" ")}\nKs ${specular.join(" ")}\n`;
    mtl += `Ke ${emission.join(" ")}\nNi 1.5\nPr ${roughness}\n`;
    if (diffuseMap) mtl += `map_Kd ${diffuseMap}\n`;
    if (specularMap) mtl += `map_Ks ${specularMap}\n`;
    if (emissionMap) mtl += `map_Ke ${emissionMap}\n`;
    mtl += "\n";
    ++materialCount;
  }
}
fs.writeFileSync(mtlPath, mtl);

const fd = fs.openSync(outputPath, "w");
let chunk = `mtllib ${path.basename(mtlPath)}\nvt 0 0\n`;
function emit(text) {
  chunk += text;
  if (chunk.length >= 4 * 1024 * 1024) { fs.writeSync(fd, chunk); chunk = ""; }
}

let vertexBase = 1, texcoordBase = 2;
let vertexCount = 0, triangleCount = 0, primitiveCount = 0;
const aabbMin = [Infinity, Infinity, Infinity], aabbMax = [-Infinity, -Infinity, -Infinity];

function emitPrimitive(ctx, modelIndex, primitive, world, label) {
  if ((primitive.mode ?? 4) !== 4) fail(`${label}: only triangle primitives are supported`);
  if (primitive.indices === undefined) fail(`${label}: non-indexed primitives are not supported`);
  const positions = accessorReader(ctx, primitive.attributes.POSITION);
  const texcoords = primitive.attributes.TEXCOORD_0 === undefined ? null
    : accessorReader(ctx, primitive.attributes.TEXCOORD_0);
  const indices = accessorReader(ctx, primitive.indices);
  if (texcoords && texcoords.count !== positions.count) fail(`${label}: POSITION/TEXCOORD_0 count mismatch`);
  emit(`o ${label}\nusemtl material_${materialBases[modelIndex] + (primitive.material ?? 0)}\n`);
  for (let i = 0; i < positions.count; ++i) {
    const p = transformPoint(world, positions.get(i));
    for (let axis = 0; axis < 3; ++axis) {
      aabbMin[axis] = Math.min(aabbMin[axis], p[axis]);
      aabbMax[axis] = Math.max(aabbMax[axis], p[axis]);
    }
    emit(`v ${p[0]} ${p[1]} ${p[2]}\n`);
  }
  if (texcoords)
    for (let i = 0; i < texcoords.count; ++i) {
      const uv = texcoords.get(i);
	  // Scene.cpp negates OBJ V coordinates. Pre-negate glTF's V coordinate so
	  // the value sampled by VkNRC matches the source glTF convention.
      emit(`vt ${uv[0]} ${-uv[1]}\n`);
    }
  for (let i = 0; i < indices.count; i += 3) {
    const face = [];
    for (let c = 0; c < 3; ++c) {
      const index = indices.get(i + c)[0];
      face.push(`${vertexBase + index}/${texcoords ? texcoordBase + index : 1}`);
    }
    emit(`f ${face.join(" ")}\n`);
  }
  vertexBase += positions.count;
  if (texcoords) texcoordBase += texcoords.count;
  vertexCount += positions.count;
  triangleCount += indices.count / 3;
  ++primitiveCount;
}

function visitModelNode(ctx, modelIndex, nodeIndex, parentWorld, graphIndex) {
  const node = ctx.gltf.nodes[nodeIndex];
  const world = multiply(parentWorld, nodeMatrix(node));
  if (node.mesh !== undefined) {
    const mesh = ctx.gltf.meshes[node.mesh];
    mesh.primitives.forEach((primitive, primitiveIndex) =>
      emitPrimitive(ctx, modelIndex, primitive, world,
        `graph_${graphIndex}_node_${nodeIndex}_mesh_${node.mesh}_primitive_${primitiveIndex}`));
  }
  for (const child of node.children ?? []) visitModelNode(ctx, modelIndex, child, world, graphIndex);
}

for (let graphIndex = 0; graphIndex < scene.graph.length; ++graphIndex) {
  const entry = scene.graph[graphIndex];
  if (entry.model === undefined) continue;
  const ctx = models[entry.model];
  const gltfScene = ctx.gltf.scenes[ctx.gltf.scene ?? 0];
  const outer = graphMatrix(entry);
  for (const root of gltfScene.nodes ?? []) visitModelNode(ctx, entry.model, root, outer, graphIndex);
}
if (chunk) fs.writeSync(fd, chunk);
fs.closeSync(fd);

const extent = aabbMax.map((value, axis) => value - aabbMin[axis]);
const center = aabbMax.map((value, axis) => (value + aabbMin[axis]) * 0.5);
const normalizationScale = 2 / Math.max(...extent);
const cameraEntry = scene.graph.find((entry) => entry.type === "PerspectiveCamera");
const cameraPosition = cameraEntry?.translation ?? [0, 0, 0];
const normalizedCameraPosition = cameraPosition.map((value, axis) => (value - center[axis]) * normalizationScale);
const manifest = {
  sourceScene: scenePath,
  outputObj: outputPath,
  outputMtl: mtlPath,
  vertices: vertexCount,
  triangles: triangleCount,
  primitives: primitiveCount,
  materials: materialCount,
  textures: copiedTextures.size,
  sourceAabb: { min: aabbMin, max: aabbMax, center, extent },
  normalizationScale,
  camera: cameraEntry ? {
    sourcePosition: cameraPosition,
    normalizedPosition: normalizedCameraPosition,
    rotation: cameraEntry.rotation ?? [0, 0, 0, 0],
    verticalFov: cameraEntry.verticalFov,
    zNear: cameraEntry.zNear,
    exposureCompensation: cameraEntry.exposureCompensation,
    exposureValue: cameraEntry.exposureValue,
  } : null,
  directionalLights: scene.graph.flatMap((entry) => entry.children ?? [])
    .filter((entry) => entry.type === "DirectionalLight")
    .map((entry) => ({
      name: entry.name,
      radianceScale: entry.radianceScale,
      angularSize: entry.angularSize,
      translation: entry.translation,
      rotation: entry.rotation,
    })),
};
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
