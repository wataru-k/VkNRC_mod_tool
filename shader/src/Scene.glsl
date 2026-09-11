#ifndef SCENE_GLSL
#define SCENE_GLSL

#ifndef SCENE_SET_ID
#define SCENE_SET_ID 0
#endif

struct Vertex {
	float x, y, z;
};

struct Material {
	vec3 diffuse;
	uint diffuse_texture_id;
	vec3 specular;
	uint specular_texture_id;
	vec3 emission;
	uint emission_texture_id;
	float metallic, roughness, ior;
	uint normal_texture_id;
};

#ifdef SCENE_TLAS_BINDING
layout(set = SCENE_SET_ID, binding = SCENE_TLAS_BINDING) uniform accelerationStructureEXT uTLAS;
#endif

#ifdef SCENE_TANGENTS_BINDING
layout(std430, set = SCENE_SET_ID, binding = SCENE_TANGENTS_BINDING) readonly buffer uuTangents {
	vec4 uTangents[];
};
#endif

#ifdef SCENE_NORMALS_BINDING
layout(std430, set = SCENE_SET_ID, binding = SCENE_NORMALS_BINDING) readonly buffer uuNormals {
	Vertex uNormals[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_NORMALS_BINDING + 1) readonly buffer uuNormalIndices {
	uint uNormalIndices[];
};
#endif

#ifdef SCENE_BUFFERS_FIRST_BINDING
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING) readonly buffer uuVertices {
	Vertex uVertices[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 1) readonly buffer uuVertexIndices {
	uint uVertexIndices[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 2) readonly buffer uuTexcoords {
	vec2 uTexcoords[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 3) readonly buffer uuTexcoordIndices {
	uint uTexcoordIndices[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 4) readonly buffer uuMaterials {
	Material uMaterials[];
};
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 5) readonly buffer uuMaterialIDs {
	uint uMaterialIDs[];
}; // Per-Primitive
layout(std430, set = SCENE_SET_ID, binding = SCENE_BUFFERS_FIRST_BINDING + 6) readonly buffer uuTransforms {
	mat3x4 uTransforms[];
}; // Per-Instance
#endif

vec3 GetSceneVertex(in const uint instance_id, in const uint primitive_id, in const uint vert_id) {
	Vertex v = uVertices[uVertexIndices[primitive_id * 3 + vert_id]];
	return vec4(v.x, v.y, v.z, 1.0) * uTransforms[instance_id];
}
vec2 GetSceneTexcoord(in const uint primitive_id, in const uint vert_id) {
	return uTexcoords[uTexcoordIndices[primitive_id * 3 + vert_id]];
}
#ifdef SCENE_NORMALS_BINDING
vec3 GetSceneNormal(in const uint instance_id, in const uint primitive_id, in const uint vert_id) {
	Vertex n = uNormals[uNormalIndices[primitive_id * 3 + vert_id]];
	return vec4(n.x, n.y, n.z, 0.0) * uTransforms[instance_id];
}
#endif
#ifdef SCENE_TANGENTS_BINDING
vec4 GetSceneTangent(in const uint instance_id, in const uint primitive_id, in const uint vert_id) {
	vec4 tangent = uTangents[uVertexIndices[primitive_id * 3 + vert_id]];
	return vec4(vec4(tangent.xyz, 0.0) * uTransforms[instance_id], tangent.w);
}
#endif
Material GetSceneMaterial(in const uint primitive_id) { return uMaterials[uMaterialIDs[primitive_id]]; }

#if defined(SCENE_TEXTURE_BINDING) && defined(SCENE_TEXTURE_NUM_CONST_ID)
layout(constant_id = SCENE_TEXTURE_NUM_CONST_ID) const uint kTextureNum = 1024;
layout(set = SCENE_SET_ID, binding = SCENE_TEXTURE_BINDING) uniform sampler2D uTextures[kTextureNum];

vec3 GetSceneDiffuse(in const Material mat, in const vec2 texcoord) {
	return mat.diffuse_texture_id == -1 ? mat.diffuse : texture(uTextures[mat.diffuse_texture_id], texcoord).rgb;
}
vec3 GetSceneSpecular(in const Material mat, in const vec2 texcoord) {
	return mat.specular_texture_id == -1 ? mat.specular : texture(uTextures[mat.specular_texture_id], texcoord).rgb;
}
vec3 GetSceneEmission(in const Material mat, in const vec2 texcoord) {
	return mat.emission_texture_id == -1 ? mat.emission : texture(uTextures[mat.emission_texture_id], texcoord).rgb;
}
vec3 GetSceneNormalSample(in const Material mat, in const vec2 texcoord) {
	return mat.normal_texture_id == -1 ? vec3(0, 0, 1)
	                                    : texture(uTextures[mat.normal_texture_id], texcoord).xyz * 2.0 - 1.0;
}
#endif

#endif
