// These are the unchanged GenericRenderer OpenGL uniform and cell byte layouts.
// See the ABI assertions in shaders.zig. Constant buffers retain explicit slots.
cbuffer Globals : register(b0) { uint4 globals[9]; };
Texture2D<float> atlas_gray : register(t0);
Texture2D<float4> atlas_color : register(t1);
ByteAddressBuffer text_cells : register(t2);
ByteAddressBuffer bg_cells : register(t3);

uint word(uint n) { return globals[n / 4][n % 4]; }
float2 cell_size() { return asfloat(uint2(word(18), word(19))); }
uint2 unpack2(uint v) { return uint2(v & 65535, v >> 16); }
float4 unpack_color(uint v) {
    return float4(v & 255, (v >> 8) & 255, (v >> 16) & 255, v >> 24) / 255.0;
}
float linearize(float v) { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
float unlinearize(float v) { return v <= 0.0031308 ? v * 12.92 : pow(max(v, 0.0), 1.0 / 2.4) * 1.055 - 0.055; }
float3 linearize3(float3 v) { return float3(linearize(v.r), linearize(v.g), linearize(v.b)); }
float3 unlinearize3(float3 v) { return float3(unlinearize(v.r), unlinearize(v.g), unlinearize(v.b)); }
float4 load_color(uint v, bool linear_blend) {
    float4 c = unpack_color(v);
    if (linear_blend) c.rgb = linearize3(c.rgb);
    c.rgb *= c.a;
    return c;
}
float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
float contrast_ratio(float3 a, float3 b) {
    float x = luminance(a) + 0.05, y = luminance(b) + 0.05;
    return max(x, y) / min(x, y);
}
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    if (contrast_ratio(fg.rgb, bg.rgb) >= min_ratio) return fg;
    return contrast_ratio(float3(1, 1, 1), bg.rgb) > contrast_ratio(float3(0, 0, 0), bg.rgb)
        ? float4(1, 1, 1, 1) : float4(0, 0, 0, 1);
}
float4 bg_vs(uint vid : SV_VertexID) : SV_Position {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 bg_ps(float4 position : SV_Position) : SV_Target {
    return load_color(word(32), (word(33) & 4) != 0);
}
float4 cellbg_ps(float4 position : SV_Position) : SV_Target {
    uint2 grid = unpack2(word(20));
    if (grid.x == 0 || grid.y == 0) return 0;
    float4 padding = asfloat(globals[6]);
    int2 pos = int2(floor((position.xy - padding.wx) / cell_size()));
    uint extend = word(28);
    if ((pos.x < 0 && !(extend & 1)) || (pos.x >= (int)grid.x && !(extend & 2)) ||
        (pos.y < 0 && !(extend & 4)) || (pos.y >= (int)grid.y && !(extend & 8))) return 0;
    pos = clamp(pos, int2(0, 0), int2(grid) - 1);
    return load_color(bg_cells.Load((pos.y * grid.x + pos.x) * 4), (word(33) & 4) != 0);
}
struct TextOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
    nointerpolation uint atlas : TEXCOORD1;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 background : COLOR1;
};
TextOut text_vs(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    uint offset = iid * 32;
    uint2 glyph_pos = text_cells.Load2(offset);
    uint2 glyph_size = text_cells.Load2(offset + 8);
    uint packed_bearings = text_cells.Load(offset + 16);
    int2 bearings = int2((int)(packed_bearings << 16) >> 16, (int)packed_bearings >> 16);
    uint2 grid_pos = unpack2(text_cells.Load(offset + 20));
    uint glyph_color = text_cells.Load(offset + 24);
    uint metadata = text_cells.Load(offset + 28);
    uint glyph_flags = (metadata >> 8) & 255;
    float2 corner = float2(vid == 1 || vid == 3, vid == 2 || vid == 3);
    float2 size = cell_size();
    float2 cell_pos = size * grid_pos + glyph_size * corner + float2(bearings.x, size.y - bearings.y);
    TextOut o;
    // The core's matrix is column-major, with clip Y already pointing up.
    o.position = asfloat(globals[0]) * cell_pos.x + asfloat(globals[1]) * cell_pos.y + asfloat(globals[3]);
    o.position.z = 0;
    o.tex_coord = glyph_pos + glyph_size * corner;
    o.atlas = metadata & 255;
    o.color = load_color(glyph_color, true);
    uint2 grid = unpack2(word(20));
    o.background = load_color(bg_cells.Load((grid_pos.y * grid.x + grid_pos.x) * 4), true);
    o.background += load_color(word(32), true) * (1.0 - o.background.a);
    float min_contrast = asfloat(word(29));
    if (min_contrast > 1.0 && !(glyph_flags & 1)) o.color = contrasted_color(min_contrast, o.color, o.background);
    uint2 cursor = unpack2(word(30));
    bool cursor_pos = (grid_pos.x == cursor.x || ((word(33) & 1) && grid_pos.x == cursor.x + 1)) && grid_pos.y == cursor.y;
    if (!(glyph_flags & 2) && cursor_pos) o.color = load_color(word(31), (word(33) & 4) != 0);
    return o;
}
float4 text_ps(TextOut i) : SV_Target {
    bool linear_blend = (word(33) & 4) != 0;
    // Pixel-coordinate nearest sampling exactly matches the GL atlas sampler.
    int2 pixel = int2(floor(i.tex_coord));
    if (i.atlas == 1) {
        float4 c = atlas_color.Load(int3(pixel, 0));
        if (!linear_blend && c.a > 0) c.rgb = unlinearize3(c.rgb / c.a) * c.a;
        return c;
    }
    float4 c = i.color;
    if (!linear_blend && c.a > 0) c.rgb = unlinearize3(c.rgb / c.a) * c.a;
    float a = atlas_gray.Load(int3(pixel, 0));
    if ((word(33) & 8) != 0) {
        float fg_l = luminance(c.rgb), bg_l = luminance(i.background.rgb);
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
            a = saturate((blend_l - bg_l) / (fg_l - bg_l));
        }
    }
    return c * a;
}
