#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

if (process.argv.length !== 4) {
  fail("usage: node tools/convert-gltf-to-vknrc-obj.mjs <input.gltf> <output.obj>");
}

const inputPath = path.resolve(process.argv[2]);
const outputPath = path.resolve(process.argv[3]);
const outputDir = path.dirname(outputPath);
const mtlPath = path.join(outputDir, `${path.parse(outputPath).name}.mtl`);
fs.mkdirSync(outputDir, { recursive: true });

const gltf = JSON.parse(fs.readFileSync(inputPath, "utf8"));
if (!Array.isArray(gltf.buffers) || gltf.buffers.length !== 1)
  fail("only a single external glTF buffer is supported");
const bufferUri = gltf.buffers[0].uri;
if (!bufferUri || bufferUri.startsWith("data:"))
  fail("an external binary buffer URI is required");
const binary = fs.readFileSync(path.resolve(path.dirname(inputPath), decodeURIComponent(bufferUri)));

const componentBytes = new Map([[5121, 1], [5122, 2], [5123, 2], [5125, 4], [5126, 4]]);
const componentCounts = new Map([["SCALAR", 1], ["VEC2", 2], ["VEC3", 3], ["VEC4", 4]]);

function readComponent(offset, type, normalized) {
  let value;
  switch (type) {
    case 5121: value = binary.readUInt8(offset); break;
    case 5122: value = binary.readInt16LE(offset); break;
    case 5123: value = binary.readUInt16LE(offset); break;
    case 5125: value = binary.readUInt32LE(offset); break;
    case 5126: return binary.readFloatLE(offset);
    default: fail(`unsupported component type ${type}`);
  }
  if (!normalized) return value;
  if (type === 5121) return value / 255;
  if (type === 5122) return Math.max(value / 32767, -1);
  if (type === 5123) return value / 65535;
  if (type === 5125) return value / 4294967295;
  return value;
}

function accessorReader(accessorIndex) {
  const accessor = gltf.accessors[accessorIndex];
  if (!accessor || accessor.sparse) fail(`unsupported accessor ${accessorIndex}`);
  const view = gltf.bufferViews[accessor.bufferView];
  const bytes = componentBytes.get(accessor.componentType);
  const count = componentCounts.get(accessor.type);
  if (!view || !bytes || !count) fail(`unsupported accessor layout ${accessorIndex}`);
  const base = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  const stride = view.byteStride ?? bytes * count;
  return {
    count: accessor.count,
    get(index) {
      const result = new Array(count);
      const start = base + index * stride;
      for (let c = 0; c < count; ++c)
        result[c] = readComponent(start + c * bytes, accessor.componentType, accessor.normalized === true);
      return result;
    },
  };
}

function identity() {
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
}

function multiply(a, b) {
  const out = new Array(16).fill(0);
  for (let col = 0; col < 4; ++col)
    for (let row = 0; row < 4; ++row)
      for (let k = 0; k < 4; ++k)
        out[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k];
  return out;
}

function localMatrix(node) {
  if (node.matrix) return node.matrix;
  const [x, y, z, w] = node.rotation ?? [0, 0, 0, 1];
  const [sx, sy, sz] = node.scale ?? [1, 1, 1];
  const [tx, ty, tz] = node.translation ?? [0, 0, 0];
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

function transformPoint(m, p) {
  return [
    m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
    m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
    m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
  ];
}

function materialValues(material = {}) {
  const specGloss = material.extensions?.KHR_materials_pbrSpecularGlossiness;
  const diffuse = specGloss?.diffuseFactor?.slice(0, 3)
    ?? material.pbrMetallicRoughness?.baseColorFactor?.slice(0, 3) ?? [0.8, 0.8, 0.8];
  const specular = specGloss?.specularFactor ?? [0.04, 0.04, 0.04];
  const emission = material.emissiveFactor ?? [0, 0, 0];
  const roughness = specGloss ? 1 - (specGloss.glossinessFactor ?? 1)
    : (material.pbrMetallicRoughness?.roughnessFactor ?? 1);
  return { diffuse, specular, emission, roughness: Math.max(0.001, roughness) };
}

let mtl = "# Constant-factor materials generated for VkNRC. DDS textures are intentionally omitted.\n";
const materials = gltf.materials?.length ? gltf.materials : [{}];
for (let i = 0; i < materials.length; ++i) {
  const v = materialValues(materials[i]);
  mtl += `newmtl material_${i}\nKd ${v.diffuse.join(" ")}\nKs ${v.specular.join(" ")}\n`;
  mtl += `Ke ${v.emission.join(" ")}\nNi 1.5\nPr ${v.roughness}\n\n`;
}
fs.writeFileSync(mtlPath, mtl);

const fd = fs.openSync(outputPath, "w");
let chunk = `mtllib ${path.basename(mtlPath)}\n`;
function emit(text) {
  chunk += text;
  if (chunk.length >= 4 * 1024 * 1024) {
    fs.writeSync(fd, chunk);
    chunk = "";
  }
}

let vertexBase = 1;
let emittedVertices = 0;
let emittedTriangles = 0;
let emittedInstances = 0;

function emitMesh(meshIndex, world, nodeIndex) {
  const mesh = gltf.meshes[meshIndex];
  for (let primitiveIndex = 0; primitiveIndex < mesh.primitives.length; ++primitiveIndex) {
    const primitive = mesh.primitives[primitiveIndex];
    if ((primitive.mode ?? 4) !== 4) fail(`mesh ${meshIndex} primitive ${primitiveIndex} is not triangles`);
    const positions = accessorReader(primitive.attributes.POSITION);
    const indices = accessorReader(primitive.indices);
    emit(`o node_${nodeIndex}_mesh_${meshIndex}_primitive_${primitiveIndex}\n`);
    emit(`usemtl material_${primitive.material ?? 0}\n`);
    for (let i = 0; i < positions.count; ++i) {
      const p = transformPoint(world, positions.get(i));
      emit(`v ${p[0]} ${p[1]} ${p[2]}\n`);
    }
    for (let i = 0; i < indices.count; i += 3) {
      const a = vertexBase + indices.get(i)[0];
      const b = vertexBase + indices.get(i + 1)[0];
      const c = vertexBase + indices.get(i + 2)[0];
      emit(`f ${a} ${b} ${c}\n`);
    }
    vertexBase += positions.count;
    emittedVertices += positions.count;
    emittedTriangles += indices.count / 3;
    ++emittedInstances;
  }
}

function visit(nodeIndex, parentWorld) {
  const node = gltf.nodes[nodeIndex];
  const world = multiply(parentWorld, localMatrix(node));
  if (node.mesh !== undefined) emitMesh(node.mesh, world, nodeIndex);
  for (const child of node.children ?? []) visit(child, world);
}

const sceneIndex = gltf.scene ?? 0;
for (const root of gltf.scenes[sceneIndex].nodes ?? []) visit(root, identity());
if (chunk) fs.writeSync(fd, chunk);
fs.closeSync(fd);

process.stdout.write(JSON.stringify({
  input: inputPath,
  output: outputPath,
  materialLibrary: mtlPath,
  vertices: emittedVertices,
  triangles: emittedTriangles,
  meshInstances: emittedInstances,
  texturesOmitted: true,
}, null, 2) + "\n");
