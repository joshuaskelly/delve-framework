const std = @import("std");
const colors = @import("../colors.zig");
const debug = @import("../debug.zig");
const images = @import("../images.zig");
const math = @import("../math.zig");
const mem = @import("../mem.zig");
const mesh = @import("../graphics/mesh.zig");
const papp = @import("app.zig");
const sokol_gfx_backend = @import("backends/sokol/graphics.zig");

const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const debugtext = sokol.debugtext;

pub var allocator: std.mem.Allocator = undefined;

// compile built-in shaders via:
// ./sokol-shdc -i assets/shaders/default.glsl -o src/graphics/shaders/default.glsl.zig -l glsl300es:glsl330:wgsl:metal_macos:metal_ios:metal_sim:hlsl4 -f sokol_zig
pub const shader_default = @import("../graphics/shaders/default.glsl.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
pub const Color = colors.Color;

pub var tex_white: Texture = undefined;
pub var tex_black: Texture = undefined;
pub var tex_grey: Texture = undefined;

// TODO: Where should the math library stuff live?
// Foster puts everything in places like /Spatial or /Graphics
// Look into using a third party math.zig instead of sokol's
// A vertex struct with position, color and uv-coords
// TODO: Stop using packed color and uvs!

pub const BlendMode = enum {
    NONE, // opaque!
    BLEND,
    ADD,
    MOD,
    MUL,
};

pub const CompareFunc = enum(i32) {
    DEFAULT,
    NEVER,
    LESS,
    EQUAL,
    LESS_EQUAL,
    GREATER,
    NOT_EQUAL,
    GREATER_EQUAL,
    ALWAYS,
    NUM,
};

pub const CullMode = enum(i32) {
    NONE,
    FRONT,
    BACK,
};

pub const IndexSize = enum(i32) {
    UINT16,
    UINT32,
};

pub const FilterMode = enum(i32) {
    NEAREST,
    LINEAR,
};

pub const ShaderStage = enum(i32) {
    VS,
    FS,
};

/// The set of material uniforms that can be binded automatically
pub const MaterialUniformDefaults = enum(i32) {
    PROJECTION_VIEW_MATRIX,
    MODEL_MATRIX,
    COLOR,
    COLOR_OVERRIDE,
    ALPHA_CUTOFF,
    JOINTS_64,
    JOINTS_256,
    CAMERA_POSITION,
    AMBIENT_LIGHT,
    DIRECTIONAL_LIGHT,
    POINT_LIGHTS_8,
    POINT_LIGHTS_16,
    POINT_LIGHTS_32,
};

// Default uniform block layout for meshes
pub const default_vs_uniforms: []const MaterialUniformDefaults = &[_]MaterialUniformDefaults{ .PROJECTION_VIEW_MATRIX, .MODEL_MATRIX, .COLOR };
pub const default_fs_uniforms: []const MaterialUniformDefaults = &[_]MaterialUniformDefaults{ .COLOR_OVERRIDE, .ALPHA_CUTOFF };

// Default VS uniform block layout for skinned meshes
pub const default_skinned_mesh_vs_uniforms: []const MaterialUniformDefaults = &[_]MaterialUniformDefaults{ .PROJECTION_VIEW_MATRIX, .MODEL_MATRIX, .COLOR, .JOINTS_64 };

// Default FS uniform block layout for the basic lighting shader
pub const default_lit_fs_uniforms: []const MaterialUniformDefaults = &[_]MaterialUniformDefaults{ .CAMERA_POSITION, .COLOR_OVERRIDE, .ALPHA_CUTOFF, .AMBIENT_LIGHT, .DIRECTIONAL_LIGHT, .POINT_LIGHTS_16 };

/// Default vertex shader uniform block layout
pub const VSDefaultUniforms = struct {
    projViewMatrix: math.Mat4 align(16),
    modelMatrix: math.Mat4,
    in_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

/// Default fragment shader uniform block layout
pub const FSDefaultUniforms = struct {
    in_color_override: [4]f32 align(16) = .{ 0.0, 0.0, 0.0, 0.0 },
    in_alpha_cutoff: f32 = 0.0,
};

// A struct that could contain anything
pub const Anything = struct {
    ptr: ?*const anyopaque = null,
    size: usize = 0,
};

// The camera view matrices that will be passed to draw calls
pub const CameraMatrices = struct {
    view: Mat4,
    proj: Mat4,
};

/// A packed mesh vertex
pub const PackedVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32 = 0xFFFFFFFF,
    u: f32 = 0,
    v: f32 = 0,

    pub fn mulMat4(left: PackedVertex, right: Mat4) PackedVertex {
        var ret = left;
        const vec = Vec3.new(left.x, left.y, left.z).mulMat4(right);
        ret.x = vec.x;
        ret.y = vec.y;
        ret.z = vec.z;
        return ret;
    }

    pub fn getPosition(self: *const PackedVertex) Vec3 {
        return Vec3.new(self.x, self.y, self.z);
    }
};

// An unpacked mesh vertex. Will need to be turned into a packed mesh vertex for rendering
pub const Vertex = struct {
    pos: Vec3 = Vec3.zero,
    uv: Vec2 = Vec2.zero,
    color: colors.Color = colors.white,
    normal: Vec3 = Vec3.y_axis,
    tangent: Vec4 = Vec4.new(1.0, 0.0, 0.0, 1.0),

    pub fn mulMat4(left: Vertex, right: Mat4) Vertex {
        var ret = left;
        ret.pos = left.pos.mulMat4(right);
        ret.normal = left.normal.mulMat4(right);
        ret.tangent = left.tangent.mulMat4(right);
        return ret;
    }

    // returns the packed version of this vertex
    pub fn pack(self: *const Vertex) PackedVertex {
        return .{ .x = self.pos.x, .y = self.pos.y, .z = self.pos.z, .u = self.uv.x, .v = self.uv.y, .color = self.color.toInt() };
    }
};

pub const PointLight = struct {
    pos: Vec3 = Vec3.zero,
    color: Color = colors.white,
    radius: f32 = 1.0,
    falloff: f32 = 1.0,
    brightness: f32 = 1.0,

    // Pack this light into eight floats so that it can be passed as two vec4s
    pub fn toArray(self: *const PointLight) [8]f32 {
        return [_]f32{ self.pos.x, self.pos.y, self.pos.z, self.radius, self.color.r * self.brightness, self.color.g * self.brightness, self.color.b * self.brightness, self.falloff };
    }
};

pub const DirectionalLight = struct {
    dir: Vec3 = Vec3.y_axis,
    brightness: f32 = 1.0,
    color: Color = colors.white,

    // Pack this light into eight floats so that it can be passed as two vec4s
    pub fn toArray(self: *const DirectionalLight) [8]f32 {
        return [_]f32{ self.dir.x, self.dir.y, self.dir.z, self.brightness, self.color.r, self.color.g, self.color.b, self.color.a };
    }
};

/// The options used when creating a new Binding
pub const BindingConfig = struct {
    updatable: bool = false,
    vert_len: usize = 3200,
    index_len: usize = 3200,
    vertex_layout: VertexLayout = getDefaultVertexLayout(),
};

/// The actual internal bindings implementation
pub const BindingsImpl = sokol_gfx_backend.BindingsImpl;

/// Bindings are a drawable collection of buffers, textures, and samplers
pub const Bindings = struct {
    length: usize,
    config: BindingConfig,
    impl: BindingsImpl,
    vertex_layout: VertexLayout,

    pub fn init(cfg: BindingConfig) Bindings {
        return BindingsImpl.init(cfg);
    }

    /// Creates new buffers to hold these vertices and indices
    pub fn set(self: *Bindings, vertices: anytype, indices: anytype, normals: anytype, tangents: anytype, length: usize) void {
        BindingsImpl.set(self, vertices, indices, normals, tangents, length);
    }

    /// Creates new buffers to hold vertices, indices, and joints / weights
    pub fn setWithJoints(self: *Bindings, vertices: anytype, indices: anytype, normals: anytype, tangents: anytype, joints: anytype, weights: anytype, length: usize) void {
        BindingsImpl.setWithJoints(self, vertices, indices, normals, tangents, joints, weights, length);
    }

    /// Updates the existing buffers with new data
    pub fn update(self: *Bindings, vertices: anytype, indices: anytype, vert_len: usize, index_len: usize) void {
        BindingsImpl.update(self, vertices, indices, vert_len, index_len);
    }

    /// Sets the texture that will be used to draw this binding
    pub fn setTexture(self: *Bindings, texture: Texture) void {
        BindingsImpl.setTexture(self, texture);
    }

    /// Sets values from the material that will be used to draw this
    fn updateFromMaterial(self: *Bindings, material: *Material) void {
        BindingsImpl.updateFromMaterial(self, material);
    }

    /// Destroy our binding
    pub fn destroy(self: *Bindings) void {
        BindingsImpl.destroy(self);
    }

    /// Resize buffers used by our binding. Will destroy buffers and recreate them!
    pub fn resize(self: *Bindings, vertex_len: usize, index_len: usize) void {
        BindingsImpl.resize(self, vertex_len, index_len);
    }
};

pub const VertexFormat = enum(i32) {
    FLOAT2,
    FLOAT3,
    FLOAT4,
    UBYTE4N,
};

pub const VertexBinding = enum(i32) {
    VERT_PACKED,
    VERT_NORMALS,
    VERT_TANGENTS,
    VERT_JOINTS,
    VERT_WEIGHTS,
};

/// A vertex layout tells a shader how to use its attributes.
pub const VertexLayout = struct {
    attributes: []const VertexLayoutAttribute,
    has_index_buffer: bool = true,
    index_size: IndexSize = .UINT32,
};

/// A vertex layout attribute holds the specifics about parts of a vertex
pub const VertexLayoutAttribute = struct {
    binding: VertexBinding = .VERT_PACKED,
    buffer_slot: u8 = 0,
    item_size: usize = @sizeOf(PackedVertex),
};

/// A shader's view of the vertex attributes
pub const ShaderAttribute = struct {
    name: [:0]const u8,
    attr_type: VertexFormat,
    binding: VertexBinding = .VERT_PACKED,
};

/// The options used when creating a new shader
pub const ShaderConfig = struct {
    blend_mode: BlendMode = .NONE,
    depth_write_enabled: bool = true,
    depth_compare: CompareFunc = .LESS_EQUAL,
    cull_mode: CullMode = .NONE,
    vertex_attributes: []const ShaderAttribute = &[_]ShaderAttribute{
        .{ .name = "pos", .attr_type = .FLOAT3, .binding = .VERT_PACKED },
        .{ .name = "color0", .attr_type = .UBYTE4N, .binding = .VERT_PACKED },
        .{ .name = "texcoord0", .attr_type = .FLOAT2, .binding = .VERT_PACKED },
    },
    is_depth_pixel_format: bool = false,
};

/// The actual backend implementation for shaders
pub const ShaderImpl = sokol_gfx_backend.ShaderImpl;

pub var next_shader_handle: u32 = 0;

/// A shader is a program that will run per-vertex and per-pixel
pub const Shader = struct {
    handle: u32,
    cfg: ShaderConfig,

    vertex_attributes: []const ShaderAttribute,

    // uniform blocks to use for the next draw call
    fs_uniform_blocks: [3]?Anything = [_]?Anything{null} ** 3,
    vs_uniform_blocks: [3]?Anything = [_]?Anything{null} ** 3,

    fs_texture_slots: u8 = 1,
    fs_sampler_slots: u8 = 1,
    fs_uniform_slots: u8 = 1,

    vs_texture_slots: u8 = 0,
    vs_sampler_slots: u8 = 0,
    vs_uniform_slots: u8 = 1,

    impl: ShaderImpl,

    /// Create a new shader using the default
    pub fn initDefault(cfg: ShaderConfig) Shader {
        return ShaderImpl.initDefault(cfg);
    }

    // TODO: Add support for loading shaders from built files as well!
    // Sokol supports exporting to multiple shader formats alongside a YAML definition file,
    // we could load that definition and the correct file based on the current backend.

    /// Creates a shader from a shader built in as a zig file
    pub fn initFromBuiltin(cfg: ShaderConfig, comptime builtin: anytype) ?Shader {
        return ShaderImpl.initFromBuiltin(cfg, builtin);
    }

    /// Returns a copy of this shader
    pub fn cloneFromShader(cfg: ShaderConfig, shader: ?Shader) Shader {
        return ShaderImpl.cloneFromShader(cfg, shader);
    }

    /// Updates the graphics state to draw using this shader
    pub fn apply(self: *Shader, layout: VertexLayout) bool {
        return ShaderImpl.apply(self, layout);
    }

    /// Sets a uniform variable block on this shader
    pub fn applyUniformBlock(self: *Shader, stage: ShaderStage, slot: u8, data: Anything) void {
        switch (stage) {
            .VS => {
                self.vs_uniform_blocks[slot] = data;
            },
            .FS => {
                self.fs_uniform_blocks[slot] = data;
            },
        }
    }

    pub fn destroy(self: *Shader) void {
        return ShaderImpl.destroy(self);
    }
};

var next_texture_handle: u32 = 0;

/// A texture is a drawable image in graphics memory
pub const Texture = struct {
    width: u32,
    height: u32,
    handle: u32,
    is_render_target: bool = false,

    sokol_image: ?sg.Image,

    /// Creates a new texture from an Image
    pub fn init(image: *images.Image) Texture {
        defer next_texture_handle += 1;

        var img_desc: sg.ImageDesc = .{
            .width = @intCast(image.width),
            .height = @intCast(image.height),
            .pixel_format = .RGBA8,
        };

        img_desc.data.subimage[0][0] = sg.asRange(image.data);

        return Texture{
            .width = image.width,
            .height = image.height,
            .sokol_image = sg.makeImage(img_desc),
            .handle = next_texture_handle,
        };
    }

    /// Creates a new Texture from the given image bytes
    pub fn initFromBytes(width: u32, height: u32, image_bytes: anytype) Texture {
        defer next_texture_handle += 1;

        var img_desc: sg.ImageDesc = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .pixel_format = .RGBA8,
        };

        img_desc.data.subimage[0][0] = sg.asRange(image_bytes);

        return Texture{
            .width = width,
            .height = height,
            .sokol_image = sg.makeImage(img_desc),
            .handle = next_texture_handle,
        };
    }

    /// Creates a texture to be used as a render pass texture
    pub fn initRenderTexture(width: u32, height: u32, is_depth: bool) Texture {
        defer next_texture_handle += 1;

        var img_desc: sg.ImageDesc = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .render_target = true,
            .sample_count = 1,
        };

        if (is_depth)
            img_desc.pixel_format = .DEPTH_STENCIL;

        return Texture{
            .width = width,
            .height = height,
            .sokol_image = sg.makeImage(img_desc),
            .handle = next_texture_handle,
            .is_render_target = true,
        };
    }

    pub fn destroy(self: *Texture) void {
        if (self.sokol_image == null)
            return;
        sg.destroyImage(self.sokol_image.?);
        self.sokol_image = null;
    }
};

pub const RenderPassConfig = struct {
    width: u32,
    height: u32,
    include_color: bool = true,
    include_depth: bool = true,
    include_stencil: bool = true,
    write_color: bool = true,
    write_depth: bool = false,
    write_stencil: bool = false,
};

/// A render pass describes an offscreen render target
pub const RenderPass = struct {
    render_texture_color: ?Texture,
    render_texture_depth: ?Texture,
    config: RenderPassConfig,

    sokol_attachments: ?sg.Attachments,

    pub fn init(config: RenderPassConfig) RenderPass {
        var atts_desc: sg.AttachmentsDesc = .{};

        var color_attachment: ?Texture = null;
        var depth_attachment: ?Texture = null;

        if (config.include_color) {
            color_attachment = Texture.initRenderTexture(config.width, config.height, false);
            atts_desc.colors[0].image = color_attachment.?.sokol_image.?;
        }

        if (config.include_depth) {
            depth_attachment = Texture.initRenderTexture(config.width, config.height, true);
            atts_desc.depth_stencil.image = depth_attachment.?.sokol_image.?;
        }

        return RenderPass{
            .config = config,
            .render_texture_color = color_attachment,
            .render_texture_depth = depth_attachment,
            .sokol_attachments = sg.makeAttachments(atts_desc),
        };
    }

    /// Destroys a render pass and its associated textures
    pub fn destroy(self: *RenderPass) void {
        if (self.render_texture_color != null) {
            self.render_texture_color.destroy();
            self.render_texture_color = null;
        }

        if (self.render_texture_depth != null) {
            self.render_texture_depth.destroy();
            self.render_texture_depth = null;
        }

        if (self.sokol_pass != null) {
            sg.destroyPass(self.sokol_pass);
            self.sokol_pass = null;
        }
    }
};

/// Begins an offscreen pass, and ends the current pass
pub fn beginPass(render_pass: RenderPass, clear_color: ?Color) void {
    if (state.in_default_pass)
        debug.fatal("Can't call beginPass when already in the default pass! This should probably be in pre-draw.", .{});
    if (state.in_offscreen_pass)
        debug.fatal("Can't call beginPass when already in an offscreen pass! End your previous pass first.", .{});

    state.in_offscreen_pass = true;

    var pass_action = sg.PassAction{};
    pass_action.colors[0] = .{ .load_action = .LOAD, .store_action = .STORE };
    pass_action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0, .store_action = .STORE };
    pass_action.stencil = .{ .load_action = .CLEAR, .clear_value = 0.0, .store_action = .STORE };

    // Don't need to store the end result in some cases
    if (!render_pass.config.write_color)
        pass_action.colors[0].store_action = .DONTCARE;

    if (!render_pass.config.write_depth)
        pass_action.depth.store_action = .DONTCARE;

    if (!render_pass.config.write_stencil)
        pass_action.stencil.store_action = .DONTCARE;

    if (clear_color != null) {
        pass_action.colors[0].load_action = .CLEAR;
        pass_action.colors[0].clear_value = .{ .r = clear_color.?.r, .g = clear_color.?.g, .b = clear_color.?.b, .a = clear_color.?.a };
    }

    sg.beginPass(.{ .action = pass_action, .attachments = render_pass.sokol_attachments.? });
}

/// Ends the current render pass, and resumes the default
pub fn endPass() void {
    if (state.in_offscreen_pass) {
        sg.endPass();
    } else {
        debug.err("endPass was called when there was no pass to end!", .{});
    }

    state.in_offscreen_pass = false;
}

/// The options for creating a new Material
pub const MaterialConfig = struct {
    // Texture slots for easy binding
    texture_0: ?Texture = null,
    texture_1: ?Texture = null,
    texture_2: ?Texture = null,
    texture_3: ?Texture = null,
    texture_4: ?Texture = null,

    // Material options
    cull_mode: CullMode = .BACK,
    blend_mode: BlendMode = .NONE,
    depth_write_enabled: bool = true,
    depth_compare: CompareFunc = .LESS_EQUAL,

    // The parent shader to base us on
    shader: ?Shader = null,

    // The layouts of the default (0th) vertex and fragment shaders
    default_vs_uniform_layout: []const MaterialUniformDefaults = default_vs_uniforms,
    default_fs_uniform_layout: []const MaterialUniformDefaults = default_fs_uniforms,

    // Samplers to create. Defaults to making one linearly filtered sampler
    samplers: []const FilterMode = &[_]FilterMode{.LINEAR},

    // Number of uniform blocks to create. Default to 1 to always make the default block
    num_uniform_vs_blocks: u8 = 1,
    num_uniform_fs_blocks: u8 = 1,

    // whether to automatically bind the 0 slot for a material using MaterialParams
    use_default_params: bool = true,
};

/// Material params can get binded automatically to the default uniform block (0)
pub const MaterialParams = struct {
    draw_color: Color = colors.white,
    color_override: Color = colors.transparent,
    alpha_cutoff: f32 = 0.0,
    joints: []Mat4 = undefined,
    ambient_light: Color = colors.black,
    directional_light: DirectionalLight = undefined,
    point_lights: []PointLight = undefined,
};

pub const UniformBlockType = enum(i32) { BOOL, INT, UINT, FLOAT, DOUBLE, VEC2, VEC3, VEC4, MAT3, MAT4 };

/// Holds the data for and builds a uniform block that can be passed to a shader
pub const MaterialUniformBlock = struct {
    size: u64 = 0,
    bytes: std.ArrayList(u8),
    last_type: UniformBlockType = undefined,

    // TODO: Maybe the material uniform blocks should be mapped up front, data allocated, and then
    // we can easily ask for offsets into the data block instead of piecing it together

    pub fn init() MaterialUniformBlock {
        return MaterialUniformBlock{
            .bytes = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn addAlignmentPadding(self: *MaterialUniformBlock) void {
        const sizef: f64 = @floatFromInt(self.size);
        const commit_next: u64 = @intFromFloat(@ceil(sizef / 16));
        const commit_size = commit_next * 16;

        if (self.size < commit_size) {
            const diff_bytes = commit_size - self.size;
            self.addPadding(diff_bytes);
            // debug.log("Added {d} padding bytes", .{diff_bytes});
        }
    }

    pub fn addBytesFrom(self: *MaterialUniformBlock, value: anytype, uniform_type: UniformBlockType) void {
        // follow std140 packing
        if (uniform_type != self.last_type and self.size != 0) {
            self.addAlignmentPadding();
        }

        self.bytes.appendSlice(std.mem.asBytes(value)) catch {
            debug.log("Error adding material uniform!", .{});
            return;
        };

        self.size = self.bytes.items.len;
        self.last_type = uniform_type;
    }

    /// Reset state for this new frame
    pub fn begin(self: *MaterialUniformBlock) void {
        self.bytes.clearRetainingCapacity();
    }

    /// Commit data for this frame
    pub fn end(self: *MaterialUniformBlock) void {
        self.addAlignmentPadding();
    }

    /// Adds a float to the uniform block
    pub fn addFloat(self: *MaterialUniformBlock, name: [:0]const u8, val: f32) void {
        _ = name;
        self.addBytesFrom(&val, UniformBlockType.FLOAT);
    }

    /// Adds a float array to the uniform block
    pub fn addFloats(self: *MaterialUniformBlock, name: [:0]const u8, val: []f32) void {
        _ = name;
        self.addBytesFrom(&val, UniformBlockType.FLOAT);
    }

    /// Adds a matrix to the uniform block
    pub fn addMatrix(self: *MaterialUniformBlock, name: [:0]const u8, val: math.Mat4) void {
        _ = name;
        self.addBytesFrom(&val, UniformBlockType.MAT4);
    }

    /// Adds a Vec2 to the uniform block
    pub fn addVec2(self: *MaterialUniformBlock, name: [:0]const u8, val: Vec2) void {
        _ = name;
        self.addBytesFrom(&val, UniformBlockType.VEC2);
    }

    /// Adds a Vec3 to the uniform block
    pub fn addVec3(self: *MaterialUniformBlock, name: [:0]const u8, val: Vec3) void {
        _ = name;
        self.addBytesFrom(&val.toArray(), UniformBlockType.VEC3);
    }

    /// Adds a Vec4 to the uniform block
    pub fn addVec4(self: *MaterialUniformBlock, name: [:0]const u8, val: Vec4) void {
        _ = name;
        self.addBytesFrom(&val.toArray(), UniformBlockType.VEC4);
    }

    /// Adds a color to the uniform block
    pub fn addColor(self: *MaterialUniformBlock, name: [:0]const u8, val: Color) void {
        _ = name;
        self.addBytesFrom(&val.toArray(), UniformBlockType.VEC4);
    }

    /// Adds [num] bytes of padding
    pub fn addPadding(self: *MaterialUniformBlock, num: u64) void {
        defer self.size = self.bytes.items.len;

        // let the compiler help us for some common padding values
        if (num == 4) {
            const padv: u32 = 0;
            self.bytes.appendSlice(std.mem.asBytes(&padv)) catch {
                return;
            };
            return;
        }
        if (num == 8) {
            const padv: u64 = 0;
            self.bytes.appendSlice(std.mem.asBytes(&padv)) catch {
                return;
            };
            return;
        }
        if (num == 12) {
            const padv: [3]u32 = [_]u32{0} ** 3;
            self.bytes.appendSlice(std.mem.asBytes(&padv)) catch {
                return;
            };
            return;
        }

        // harder case, just add them one by one
        for (0..@intCast(num)) |i| {
            _ = i;
            const padv: u8 = 0;
            self.bytes.appendSlice(std.mem.asBytes(&padv)) catch {
                return;
            };
        }
    }
};

/// A material for drawing, consists of a shader and potentially many textures
pub const Material = struct {
    textures: [5]?Texture = [_]?Texture{null} ** 5,
    shader: Shader = undefined,
    blend_mode: BlendMode,
    depth_write_enabled: bool,
    depth_compare: CompareFunc,
    cull_mode: CullMode,
    use_default_params: bool = true,

    // Material params are used for automatic binding
    params: MaterialParams = MaterialParams{},

    /// Holds what will be automatically binded by the material
    default_vs_uniform_layout: []const MaterialUniformDefaults,
    default_fs_uniform_layout: []const MaterialUniformDefaults,

    /// Hold our shader uniforms
    vs_uniforms: [5]?MaterialUniformBlock = [_]?MaterialUniformBlock{null} ** 5,
    fs_uniforms: [5]?MaterialUniformBlock = [_]?MaterialUniformBlock{null} ** 5,

    // Hold our samplers
    sokol_samplers: [5]?sg.Sampler = [_]?sg.Sampler{null} ** 5,
    pub fn init(cfg: MaterialConfig) Material {
        var material = Material{
            .blend_mode = cfg.blend_mode,
            .depth_write_enabled = cfg.depth_write_enabled,
            .depth_compare = cfg.depth_compare,
            .cull_mode = cfg.cull_mode,
            .default_vs_uniform_layout = cfg.default_vs_uniform_layout,
            .default_fs_uniform_layout = cfg.default_fs_uniform_layout,
            .use_default_params = cfg.use_default_params,
        };

        // Make samplers from filter modes
        for (cfg.samplers, 0..) |sampler_filter, i| {
            const sampler_desc = convertFilterModeToSamplerDesc(sampler_filter);
            material.sokol_samplers[i] = sg.makeSampler(sampler_desc);
        }

        // Set textures. ugly!
        if (cfg.texture_0 != null)
            material.textures[0] = cfg.texture_0;
        if (cfg.texture_1 != null)
            material.textures[1] = cfg.texture_1;
        if (cfg.texture_2 != null)
            material.textures[2] = cfg.texture_2;
        if (cfg.texture_3 != null)
            material.textures[3] = cfg.texture_3;
        if (cfg.texture_4 != null)
            material.textures[4] = cfg.texture_4;

        // Create uniform blocks based on how many we were asked for
        for (0..cfg.num_uniform_vs_blocks) |i| {
            material.vs_uniforms[i] = MaterialUniformBlock.init();
        }
        for (0..cfg.num_uniform_fs_blocks) |i| {
            material.fs_uniforms[i] = MaterialUniformBlock.init();
        }

        var shader_config = if (cfg.shader != null) cfg.shader.?.cfg else ShaderConfig{};
        shader_config.cull_mode = cfg.cull_mode;
        shader_config.blend_mode = cfg.blend_mode;
        shader_config.depth_write_enabled = cfg.depth_write_enabled;
        shader_config.depth_compare = cfg.depth_compare;

        // make a shader out of our options
        material.shader = Shader.cloneFromShader(shader_config, cfg.shader);

        return material;
    }

    /// Frees a material
    pub fn deinit(self: *Material) void {
        for (self.vs_uniforms) |vsu| {
            allocator.free(vsu);
        }
        for (self.fs_uniforms) |fsu| {
            allocator.free(fsu);
        }
    }

    /// Builds and applys a uniform block from a layout
    pub fn setDefaultUniformVars(self: *Material, layout: []const MaterialUniformDefaults, u_block: *MaterialUniformBlock, view_matrix: Mat4, proj_matrix: Mat4, model_matrix: Mat4) void {
        // Don't do anything if we have no layout for the default block
        if (layout.len == 0)
            return;

        u_block.begin();
        for (layout) |item| {
            switch (item) {
                .PROJECTION_VIEW_MATRIX => {
                    u_block.addMatrix("u_projViewMatrix", proj_matrix.mul(view_matrix));
                },
                .MODEL_MATRIX => {
                    u_block.addMatrix("u_modelMatrix", model_matrix);
                },
                .COLOR => {
                    u_block.addColor("u_color", self.params.draw_color);
                },
                .COLOR_OVERRIDE => {
                    u_block.addColor("u_colorOverride", self.params.color_override);
                },
                .ALPHA_CUTOFF => {
                    u_block.addFloat("u_alphaCutoff", self.params.alpha_cutoff);
                },
                .JOINTS_64 => {
                    u_block.addBytesFrom(self.params.joints[0..64], UniformBlockType.MAT4);
                },
                .JOINTS_256 => {
                    u_block.addBytesFrom(self.params.joints[0..256], UniformBlockType.MAT4);
                },
                .CAMERA_POSITION => {
                    const inv_view = view_matrix.invert();
                    const cam_array = [_]f32{ inv_view.m[3][0], inv_view.m[3][1], inv_view.m[3][2], 0.0 };
                    u_block.addBytesFrom(&cam_array, UniformBlockType.VEC4);
                },
                .AMBIENT_LIGHT => {
                    u_block.addColor("u_ambientLight", self.params.ambient_light);
                },
                .DIRECTIONAL_LIGHT => {
                    u_block.addBytesFrom(&self.params.directional_light.toArray(), UniformBlockType.VEC4);
                },
                .POINT_LIGHTS_8 => {
                    self.addPointLightsToUniformBlock(u_block, 8);
                },
                .POINT_LIGHTS_16 => {
                    self.addPointLightsToUniformBlock(u_block, 16);
                },
                .POINT_LIGHTS_32 => {
                    self.addPointLightsToUniformBlock(u_block, 32);
                },
            }
        }
        u_block.end();
    }

    pub fn addPointLightsToUniformBlock(self: *Material, u_block: *MaterialUniformBlock, comptime max_lights: usize) void {
        const num_lights = self.params.point_lights.len;
        u_block.addFloat("u_num_point_lights", @floatFromInt(num_lights));

        // each light is packed as two vec4s
        for (0..max_lights) |i| {
            if (i < num_lights) {
                u_block.addBytesFrom(&self.params.point_lights[i].toArray(), UniformBlockType.VEC4);
            } else {
                u_block.addVec4("u_point_light_data", Vec4.new(0, 0, 0, 0));
                u_block.addVec4("u_point_light_data", Vec4.new(0, 0, 0, 0));
            }
        }
    }

    /// Applys shader uniform variables for this Material
    pub fn applyUniforms(self: *Material, cam_matrices: CameraMatrices, model_matrix: Mat4) void {
        // If no default layout is set, we'll treat the first uniform block like any other
        // otherwise, we start custom blocks at index 1.
        const has_default_vs: bool = self.default_vs_uniform_layout.len > 0;
        const has_default_fs: bool = self.default_fs_uniform_layout.len > 0;

        const view_matrix = cam_matrices.view;
        const proj_matrix = cam_matrices.proj;

        // Set our default uniform vars first
        if (has_default_vs and self.use_default_params) {
            if (self.vs_uniforms[0] != null)
                self.setDefaultUniformVars(self.default_vs_uniform_layout, &self.vs_uniforms[0].?, view_matrix, proj_matrix, model_matrix);
        }
        if (has_default_fs and self.use_default_params) {
            if (self.fs_uniforms[0] != null)
                self.setDefaultUniformVars(self.default_fs_uniform_layout, &self.fs_uniforms[0].?, view_matrix, proj_matrix, model_matrix);
        }

        // Now apply all uniform var blocks
        for (0..self.vs_uniforms.len) |i| {
            if (self.vs_uniforms[i]) |u_block| {
                if (u_block.size > 0)
                    self.shader.applyUniformBlock(.VS, @intCast(i), asAnything(u_block.bytes.items));
            }
        }
        for (0..self.fs_uniforms.len) |i| {
            if (self.fs_uniforms[i]) |u_block| {
                if (u_block.size > 0)
                    self.shader.applyUniformBlock(.FS, @intCast(i), asAnything(u_block.bytes.items));
            }
        }
    }
};

pub const state = struct {
    var debug_draw_bindings: Bindings = undefined;
    var debug_shader: Shader = undefined;
    var debug_material: Material = undefined;
    var debug_draw_color_override: Color = colors.transparent;
    var debug_text_scale: f32 = 1.0;
    var in_default_pass: bool = false;
    var in_offscreen_pass: bool = false;
};

var default_pass_action: sg.PassAction = .{};

/// Initializes the graphics subsystem
pub fn init() !void {
    debug.log("Graphics subsystem starting", .{});

    allocator = mem.getAllocator();

    // Setup some debug textures
    tex_white = createSolidTexture(0xFFFFFFFF);
    tex_black = createSolidTexture(0xFF000000);
    tex_grey = createSolidTexture(0xFF777777);

    // Setup debug text rendering
    var text_desc: debugtext.Desc = .{
        .logger = .{ .func = slog.func },
    };
    text_desc.fonts[0] = debugtext.fontOric();
    debugtext.setup(text_desc);

    // Create vertex buffer with debug quad vertices
    const debug_vertices = &[_]PackedVertex{
        .{ .x = 0.0, .y = 1.0, .z = 0.0, .color = 0xFFFFFFFF, .u = 0, .v = 0 },
        .{ .x = 1.0, .y = 1.0, .z = 0.0, .color = 0xFFFFFFFF, .u = 1, .v = 0 },
        .{ .x = 1.0, .y = 0.0, .z = 0.0, .color = 0xFFFFFFFF, .u = 1, .v = 1 },
        .{ .x = 0.0, .y = 0.0, .z = 0.0, .color = 0xFFFFFFFF, .u = 0, .v = 1 },
    };
    const debug_indices = &[_]u32{ 0, 1, 2, 0, 2, 3 };

    state.debug_draw_bindings = Bindings.init(.{});
    state.debug_draw_bindings.set(debug_vertices, debug_indices, &[_]u32{}, &[_]u32{}, 6);

    // Use the default shader for debug drawing
    state.debug_shader = Shader.initDefault(.{ .cull_mode = .NONE });
    state.debug_material = Material.init(.{
        .shader = state.debug_shader,
        .texture_0 = tex_white,
        .cull_mode = .NONE,
        .blend_mode = .NONE,
    });

    // Set the initial clear color
    default_pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1 },
    };

    debug.log("Graphics subsystem started successfully", .{});
}

/// Stops the graphics subystem
pub fn deinit() void {
    debug.log("Graphics subsystem stopping", .{});
}

/// Called at the start of a frame
pub fn startFrame() void {
    if (state.in_offscreen_pass) {
        debug.err("Started the default pass when an offscreen was still ongoing!", .{});
        endPass();
    }

    // reset debug text
    debugtext.canvas(sapp.widthf() * 0.5, sapp.heightf() * 0.5);
    debugtext.layer(0);

    state.in_default_pass = true;

    // reset to drawing to the swapchain on every frame start
    sg.beginPass(.{ .action = default_pass_action, .swapchain = sglue.swapchain() });
}

/// Called at the end of a frame
pub fn endFrame() void {
    // draw console text on a new layer
    debugtext.layer(1);
    debug.drawConsole(false);

    // draw any debug text
    debugtext.drawLayer(0);

    // draw the console text over other text
    debug.drawConsoleBackground();
    debugtext.drawLayer(1);

    // flush to the screen!
    sg.endPass();
    sg.commit();

    state.in_default_pass = false;
}

/// Sets the clear color on the default pass
pub fn setClearColor(color: Color) void {
    default_pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a },
    };
}

/// Returns a perspective projection matrix for our current app
pub fn getProjectionPerspective(fov: f32, near: f32, far: f32) Mat4 {
    const aspect = papp.getAspectRatio();
    return Mat4.persp(fov, aspect, near, far);
}

/// Returns an orthographic projection matrix for our current app
pub fn getProjectionOrtho(near: f32, far: f32, flip_y: bool) Mat4 {
    if (flip_y) {
        return Mat4.ortho(0.0, sapp.widthf(), sapp.heightf(), 0.0, near, far);
    }
    return Mat4.ortho(0.0, sapp.widthf(), 0.0, sapp.heightf(), near, far);
}

/// Returns a custom orthographic projection matrix for our current app
pub fn getProjectionOrthoCustom(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
    return Mat4.ortho(left, right, bottom, top, near, far);
}

/// Sets the debug text drawing color
pub fn setDebugTextColor(color: Color) void {
    debugtext.color4f(color.r, color.g, color.b, color.a);
}

/// Draws debug text on the screen
pub fn drawDebugText(x: f32, y: f32, str: [:0]const u8) void {
    debugtext.pos(x * (0.125 / state.debug_text_scale), y * (0.125 / state.debug_text_scale));
    debugtext.puts(str);
}

/// Draws a single debug text character
pub fn drawDebugTextChar(x: f32, y: f32, char: u8) void {
    // debugtext.pos(x * 0.125, y * 0.125);
    debugtext.pos(x * (0.125 / state.debug_text_scale), y * (0.125 / state.debug_text_scale));
    debugtext.putc(char);
}

/// Sets the scaling used when drawing debug text
pub fn setDebugTextScale(scale: f32) void {
    debugtext.canvas(sapp.widthf() / (scale * 2.0), sapp.heightf() / (scale * 2.0));
    state.debug_text_scale = scale * 2.0;
}

/// Retursn the current text scale for debug text
pub fn getDebugTextScale() f32 {
    return state.debug_text_scale;
}

/// Draws a rectangle using the slow debug draw setup
pub fn drawDebugRectangle(tex: Texture, x: f32, y: f32, width: f32, height: f32, color: Color) void {
    // apply the texture
    state.debug_draw_bindings.setTexture(tex);
    state.debug_material.textures[0] = tex_white;

    // create a view state
    var proj = getProjectionOrtho(0.001, 10.0, false);
    const view = Mat4.lookat(.{ .x = 0.0, .y = 0.0, .z = 5.0 }, Vec3.zero, Vec3.up);

    const translate_vec: Vec3 = Vec3{ .x = x, .y = @as(f32, @floatFromInt(getDisplayHeight())) - (y + height), .z = -2.5 };
    const scale_vec: Vec3 = Vec3{ .x = width, .y = height, .z = 1.0 };

    var model = Mat4.identity;
    model = model.mul(Mat4.translate(translate_vec));
    model = model.mul(Mat4.scale(scale_vec));

    // make our shader params
    const vs_params = shader_default.VsParams{
        .u_projViewMatrix = proj.mul(view),
        .u_modelMatrix = model,
        .u_color = color.toArray(),
    };

    const fs_params = shader_default.FsParams{
        .u_color_override = state.debug_draw_color_override.toArray(),
        .u_alpha_cutoff = 0.0,
    };

    // set our default vs/fs shader uniforms to the 0 slots
    state.debug_shader.applyUniformBlock(.FS, 0, asAnything(&fs_params));
    state.debug_shader.applyUniformBlock(.VS, 0, asAnything(&vs_params));

    draw(&state.debug_draw_bindings, &state.debug_shader);
}

/// Sets the color override used when drawing debug shapes
pub fn setDebugDrawColorOverride(color: Color) void {
    state.debug_draw_color_override = color;
}

/// Returns the app's display width
pub fn getDisplayWidth() i32 {
    return sapp.width();
}

/// Returns the app's display height
pub fn getDisplayHeight() i32 {
    return sapp.height();
}

/// Returns the pixel DPI scaling used for the app
pub fn getDisplayDPIScale() f32 {
    return sapp.dpiScale();
}

/// Draw part of a binding
pub fn drawSubset(bindings: *Bindings, start: u32, end: u32, shader: *Shader) void {
    BindingsImpl.drawSubset(bindings, start, end, shader);
}

/// Draw a whole binding
pub fn draw(bindings: *Bindings, shader: *Shader) void {
    drawSubset(bindings, 0, @intCast(bindings.length), shader);
}

/// Draw a part of a binding, using a material
pub fn drawSubsetWithMaterial(bindings: *Bindings, start: u32, end: u32, material: *Material, cam_matrices: CameraMatrices, model_matrix: Mat4) void {
    bindings.updateFromMaterial(material);
    material.applyUniforms(cam_matrices, model_matrix);
    drawSubset(bindings, start, end, &material.shader);
}

/// Draw a whole binding, using a material
pub fn drawWithMaterial(bindings: *Bindings, material: *Material, cam_matrices: CameraMatrices, model_matrix: Mat4) void {
    drawSubsetWithMaterial(bindings, 0, @intCast(bindings.length), material, cam_matrices, model_matrix);
}

/// Returns a small 2x2 solid color texture
pub fn createSolidTexture(color: u32) Texture {
    const img = &[2 * 2]u32{
        color, color,
        color, color,
    };
    return Texture.initFromBytes(2, 2, img);
}

/// Returns a 4x4 checkerboard texture for debugging
pub fn createDebugTexture() Texture {
    const img = &[4 * 4]u32{
        0xFF999999, 0xFF555555, 0xFF999999, 0xFF555555,
        0xFF555555, 0xFF999999, 0xFF555555, 0xFF999999,
        0xFF999999, 0xFF555555, 0xFF999999, 0xFF555555,
        0xFF555555, 0xFF999999, 0xFF555555, 0xFF999999,
    };
    return Texture.initFromBytes(4, 4, img);
}

fn convertFilterModeToSamplerDesc(filter: FilterMode) sg.SamplerDesc {
    const filter_mode = if (filter == FilterMode.LINEAR) sg.Filter.LINEAR else sg.Filter.NEAREST;
    return sg.SamplerDesc{
        .min_filter = filter_mode,
        .mag_filter = filter_mode,
        .mipmap_filter = filter_mode,
    };
}

// Taken from sokol_zig gfx, uses this to pass untyped data around
pub fn asAnything(val: anytype) Anything {
    const type_info = @typeInfo(@TypeOf(val));
    switch (type_info) {
        .Pointer => {
            switch (type_info.Pointer.size) {
                .One => return .{ .ptr = val, .size = @sizeOf(type_info.Pointer.child) },
                .Slice => return .{ .ptr = val.ptr, .size = @sizeOf(type_info.Pointer.child) * val.len },
                else => @compileError("FIXME: Pointer type!"),
            }
        },
        .Struct, .Array => {
            @compileError("Structs and arrays must be passed as pointers to asAnything");
        },
        else => {
            @compileError("Cannot convert to range!");
        },
    }
}

/// Returns the default vertex layout
pub fn getDefaultVertexLayout() VertexLayout {
    return VertexLayout{
        .attributes = &[_]VertexLayoutAttribute{
            .{
                .binding = .VERT_PACKED,
                .buffer_slot = 0,
            },
        },
    };
}

/// Gets a list of commonly used vertex layouts
pub fn getCommonVertexLayouts() []const VertexLayout {
    return &[_]VertexLayout{
        getDefaultVertexLayout(),
    };
}
