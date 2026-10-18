//! GPU compositor: N video layers (NV12 sampled directly from decoder IOSurfaces), each with a
//! transform, opacity and a colour filter, blended (premultiplied "over") into a target texture.
//! The same code renders the preview and the export, so they are pixel-identical.
use crate::gpu::Gpu;
use bytemuck::{Pod, Zeroable};
use std::sync::Arc;

pub const COMP_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Bgra8Unorm;
const MAX_LAYERS: usize = 16;
const UNIFORM_STRIDE: u64 = 256;

#[derive(Clone, Copy, Debug)]
pub struct LayerParams {
    /// Center of the layer in normalized canvas coords (0..1, y down).
    pub center: [f32; 2],
    /// Size of the layer as a fraction of the canvas.
    pub size: [f32; 2],
    pub rotation: f32,
    pub opacity: f32,
    pub saturation: f32,
    pub brightness: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct LayerUniform {
    xform: [f32; 4], // half-size (ndc), center (ndc)
    params: [f32; 4], // opacity, saturation, brightness, rotation
    aspect: [f32; 4],
}

const SHADER: &str = r#"
struct Layer { xform: vec4<f32>, params: vec4<f32>, aspect: vec4<f32> };
@group(0) @binding(0) var<uniform> L: Layer;
@group(0) @binding(1) var ytex: texture_2d<f32>;
@group(0) @binding(2) var uvtex: texture_2d<f32>;
@group(0) @binding(3) var samp: sampler;
struct VO { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> VO {
  var p = array<vec2<f32>,4>(vec2(-1.,-1.), vec2(1.,-1.), vec2(-1.,1.), vec2(1.,1.));
  let q = p[i];
  var s = q * L.xform.xy;
  // rotate in pixel space (aspect.x = canvas w/h)
  let c = cos(L.params.w); let sn = sin(L.params.w);
  s = vec2(s.x * L.aspect.x, s.y);
  s = vec2(c * s.x - sn * s.y, sn * s.x + c * s.y);
  s = vec2(s.x / L.aspect.x, s.y);
  var o: VO;
  o.pos = vec4(s + L.xform.zw, 0., 1.);
  o.uv = vec2((q.x + 1.) * 0.5, (1. - q.y) * 0.5);
  return o;
}
@fragment fn fs(in: VO) -> @location(0) vec4<f32> {
  let y = textureSample(ytex, samp, in.uv).r;
  let cb = textureSample(uvtex, samp, in.uv).rg;
  // BT.709 video range -> RGB
  let Y = (y - 16. / 255.) * (255. / 219.);
  let U = (cb.x - 128. / 255.) * (255. / 224.);
  let V = (cb.y - 128. / 255.) * (255. / 224.);
  var rgb = vec3(Y + 1.5748 * V, Y - 0.1873 * U - 0.4681 * V, Y + 1.8556 * U);
  let luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  rgb = mix(vec3(luma), rgb, L.params.y) + vec3(L.params.z);
  rgb = clamp(rgb, vec3(0.), vec3(1.));
  return vec4(rgb * L.params.x, L.params.x);
}
"#;

const BLIT: &str = r#"
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;
struct VO { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> VO {
  var p = array<vec2<f32>,4>(vec2(-1.,-1.), vec2(1.,-1.), vec2(-1.,1.), vec2(1.,1.));
  var o: VO; o.pos = vec4(p[i], 0., 1.); o.uv = vec2((p[i].x + 1.) * 0.5, (1. - p[i].y) * 0.5); return o;
}
@fragment fn fs(in: VO) -> @location(0) vec4<f32> { return textureSample(src, samp, in.uv); }
"#;

pub struct LayerInput<'a> {
    pub y: &'a wgpu::Texture,
    pub uv: &'a wgpu::Texture,
    pub params: LayerParams,
}

pub struct Compositor {
    gpu: Arc<Gpu>,
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    uniforms: wgpu::Buffer,
    sampler: wgpu::Sampler,
    blit_pipelines: Vec<(wgpu::TextureFormat, wgpu::RenderPipeline)>,
    blit_bgl: wgpu::BindGroupLayout,
    blit_module: wgpu::ShaderModule,
}

impl Compositor {
    pub fn new(gpu: Arc<Gpu>) -> Self {
        let d = &gpu.device;
        let module = d.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("comp"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let tex_entry = |b| wgpu::BindGroupLayoutEntry {
            binding: b,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let samp_entry = |b| wgpu::BindGroupLayoutEntry {
            binding: b,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        };
        let bgl = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("layer"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: true,
                        min_binding_size: None,
                    },
                    count: None,
                },
                tex_entry(1),
                tex_entry(2),
                samp_entry(3),
            ],
        });
        let layout = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });
        let premul_over = wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                operation: wgpu::BlendOperation::Add,
            },
            alpha: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                operation: wgpu::BlendOperation::Add,
            },
        };
        let pipeline = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("comp"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: COMP_FORMAT,
                    blend: Some(premul_over),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let uniforms = d.create_buffer(&wgpu::BufferDescriptor {
            label: Some("layer-uniforms"),
            size: UNIFORM_STRIDE * MAX_LAYERS as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let sampler = d.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let blit_module = d.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blit"),
            source: wgpu::ShaderSource::Wgsl(BLIT.into()),
        });
        let blit_bgl = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blit"),
            entries: &[tex_entry(0), samp_entry(1)],
        });
        Compositor {
            gpu,
            pipeline,
            bgl,
            uniforms,
            sampler,
            blit_pipelines: Vec::new(),
            blit_bgl,
            blit_module,
        }
    }

    /// Encode the composition of `layers` into `target` (cleared to black).
    pub fn encode(&self, enc: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, size: (u32, u32), layers: &[LayerInput]) {
        let aspect = size.0 as f32 / size.1 as f32;
        let mut data = vec![0u8; (UNIFORM_STRIDE as usize) * layers.len().max(1)];
        for (i, l) in layers.iter().enumerate() {
            let p = &l.params;
            let u = LayerUniform {
                xform: [p.size[0], p.size[1], p.center[0] * 2.0 - 1.0, 1.0 - p.center[1] * 2.0],
                params: [p.opacity, p.saturation, p.brightness, p.rotation],
                aspect: [aspect, 0.0, 0.0, 0.0],
            };
            let off = i * UNIFORM_STRIDE as usize;
            data[off..off + std::mem::size_of::<LayerUniform>()].copy_from_slice(bytemuck::bytes_of(&u));
        }
        self.gpu.queue.write_buffer(&self.uniforms, 0, &data);
        let views: Vec<(wgpu::TextureView, wgpu::TextureView)> = layers
            .iter()
            .map(|l| (l.y.create_view(&Default::default()), l.uv.create_view(&Default::default())))
            .collect();
        let groups: Vec<wgpu::BindGroup> = views
            .iter()
            .map(|(y, uv)| {
                self.gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &self.bgl,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                                buffer: &self.uniforms,
                                offset: 0,
                                size: wgpu::BufferSize::new(std::mem::size_of::<LayerUniform>() as u64),
                            }),
                        },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(y) },
                        wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(uv) },
                        wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                    ],
                })
            })
            .collect();
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("comp"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&self.pipeline);
        for (i, g) in groups.iter().enumerate() {
            pass.set_bind_group(0, g, &[(i as u64 * UNIFORM_STRIDE) as u32]);
            pass.draw(0..4, 0..1);
        }
    }

    fn blit_pipeline(&mut self, format: wgpu::TextureFormat) -> &wgpu::RenderPipeline {
        if !self.blit_pipelines.iter().any(|(f, _)| *f == format) {
            let d = &self.gpu.device;
            let layout = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(&self.blit_bgl)],
                immediate_size: 0,
            });
            let p = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("blit"),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &self.blit_module,
                    entry_point: Some("vs"),
                    buffers: &[],
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &self.blit_module,
                    entry_point: Some("fs"),
                    targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleStrip, ..Default::default() },
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            });
            self.blit_pipelines.push((format, p));
        }
        &self.blit_pipelines.iter().find(|(f, _)| *f == format).unwrap().1
    }

    /// Draw `src` letterboxed into `dst` (the presentation surface).
    pub fn encode_blit(
        &mut self,
        enc: &mut wgpu::CommandEncoder,
        src: &wgpu::TextureView,
        src_size: (u32, u32),
        dst: &wgpu::TextureView,
        dst_size: (u32, u32),
        dst_format: wgpu::TextureFormat,
    ) {
        self.blit_pipeline(dst_format);
        let pipeline = &self.blit_pipelines.iter().find(|(f, _)| *f == dst_format).unwrap().1;
        let group = self.gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.blit_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(src) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        let (sw, sh) = (src_size.0 as f32, src_size.1 as f32);
        let (dw, dh) = (dst_size.0 as f32, dst_size.1 as f32);
        let scale = (dw / sw).min(dh / sh);
        let (vw, vh) = (sw * scale, sh * scale);
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("blit"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: dst,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_viewport((dw - vw) / 2.0, (dh - vh) / 2.0, vw, vh, 0.0, 1.0);
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.draw(0..4, 0..1);
    }
}

/// The benchmark composition: 4 layers, each with its own transform, opacity 0.8 and a
/// saturation/brightness filter.
pub fn bench_layer_params(t: f64) -> Vec<LayerParams> {
    let wob = (t * 0.5).sin() as f32 * 0.02;
    let mut v = vec![
        LayerParams { center: [0.5, 0.5], size: [1.0, 1.0], rotation: 0.0, opacity: 0.8, saturation: 1.3, brightness: 0.02 },
        LayerParams { center: [0.3 + wob, 0.3], size: [0.55, 0.55], rotation: 0.05, opacity: 0.8, saturation: 0.6, brightness: -0.03 },
        LayerParams { center: [0.72, 0.32 + wob], size: [0.45, 0.45], rotation: -0.08, opacity: 0.8, saturation: 1.6, brightness: 0.05 },
        LayerParams { center: [0.5, 0.72], size: [0.4, 0.4], rotation: 0.0, opacity: 0.8, saturation: 0.0, brightness: 0.1 },
    ];
    // [bench harness] layers 5-8 for the 8-layer stress test (MONTAGE_LAYERS=8): same clips again,
    // smaller and offset. Callers zip with their sources, so 4-layer runs only use the first 4.
    for i in 0..4 {
        let mut p = v[i];
        p.size = [p.size[0] * 0.6, p.size[1] * 0.6];
        p.center = [0.2 + 0.6 * ((i % 2) as f32), 0.25 + 0.5 * ((i / 2) as f32)];
        v.push(p);
    }
    v
}
