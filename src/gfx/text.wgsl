//-----------------------------------------------------------------------------
// Vertex shader
//-----------------------------------------------------------------------------
struct VertexOutput {
  // Vertex position
  @builtin(position) Position : vec4<f32>,

  // UV coordinate into the glyph atlas
  @location(0) fragUV : vec2<f32>,

  // Color of the glyph
  @location(1) color : vec4<f32>,
};

// Our vertex shader will recieve these parameters
struct Uniforms {
  // The view * orthographic projection matrix
  view_projection: mat4x4<f32>,

  // Total size of the font atlas texture in pixels
  texture_size: vec2<f32>,
};

struct Glyph {
  // Position of this glyph (top-left corner.)
  pos: vec2<f32>,

  // Size of the glyph in pixels.
  size: vec2<f32>,

  // Normalized position of the top-left UV coordinate
  uv_pos: vec2<f32>,

  // Which text this glyph belongs to; this is the index for transforms[i], colors[i]
  text_index: u32,

  // TODO(d3d12): #1217
  //   Added padding for d3d12/hlsl. Having 7 floats before the color vec caused and error.
  text_index2: u32,   // Padding for struct alignment

  // Color of the glyph
  color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms : Uniforms;

@group(0) @binding(1) var<storage, read> transforms: array<mat4x4<f32>>;
@group(0) @binding(2) var<storage, read> colors: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> glyphs: array<Glyph>;

@vertex
fn vertMain(
  @builtin(vertex_index) VertexIndex : u32
) -> VertexOutput {
  var glyph = glyphs[VertexIndex / 6];
  let transform = transforms[glyph.text_index];
  let color = colors[glyph.text_index];

  // Based on the vertex index, we determine which positions[n] and uvs[n] we need to use. Our
  // vertex shader is invoked 6 times per glyph, we need to produce the right vertex/uv coordinates
  // each time to produce a textured card.
  let positions = array<vec2<f32>, 6>(
      vec2<f32>(0, 0), // left, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 1), // right, top
  );
  let uvs = array<vec2<f32>, 6>(
      vec2<f32>(0, 1), // left, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 0), // right, top
  );
  let pos_2d = positions[VertexIndex % 6];
  var uv = uvs[VertexIndex % 6];

  // Currently, our pos_2d and uv coordinates describe a card that covers 1px by 1px; and the UV
  // coordinates describe using the entire texture. We alter the coordinates to describe the
  // desired glyph location, size, and apply a subset of the texture instead of the entire texture.
  var pos = vec4<f32>((pos_2d * glyph.size) + glyph.pos, 0, 1); // normalized -> pixels
  pos = transform * pos; // apply glyph transform (pixels)
  pos = uniforms.view_projection * pos; // pixels -> normalized

  // TODO: elevate px_density out of shader
  let px_density = 2.0;
  uv *= glyph.size*px_density; // normalized -> pixels
  uv += glyph.uv_pos; // apply glyph UV position offset (pixels)
  uv /= uniforms.texture_size; // pixels -> normalized

  var output : VertexOutput;
  output.Position = pos;
  output.fragUV = uv;
  output.color = glyph.color;
  return output;
}

//-----------------------------------------------------------------------------
// Fragment shader
//-----------------------------------------------------------------------------
@group(0) @binding(4) var glyphSampler: sampler;
@group(0) @binding(5) var glyphTexture: texture_2d<f32>;

@fragment
fn fragMain(
  @location(0) fragUV: vec2<f32>,
  @location(1) color: vec4<f32>
) -> @location(0) vec4<f32> {
  var c = textureSample(glyphTexture, glyphSampler, fragUV);
  if (c.a <= 0.0) {
    discard;
  }
  return vec4<f32>(color.rgb, color.a * c.a);
}
