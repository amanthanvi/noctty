#version 430 core

// noctty divergence (#640): presents a frame whose alpha the window manager
// composes (Win32 blur-behind). With linear blending the target stores linear
// premultiplied color that the framebuffer sRGB-encodes per channel,
// srgb(c * a) with alpha a, while DWM composes sRGB-premultiplied pixels,
// srgb(c) * a. Sampling the sRGB texture decodes to c * a: divide a out,
// encode, and premultiply again. Written with GL_FRAMEBUFFER_SRGB off, so the
// bytes land as they are. An opaque pixel (a = 1) comes out unchanged.
//
// An unfocused split's dim (`dim`: the fill and its alpha, 0-1, straight) is
// laid over the converted pixel, premultiplied-over in gamma space as the
// split_dim pass blends the stored bytes of any other frame. Drawn into the
// target before this conversion, it would be read as linear light. A zero
// alpha leaves the pixel as converted.

layout(binding = 0) uniform sampler2D frame;
uniform vec2 dst_size;
uniform vec4 dim;

layout(location = 0) out vec4 out_FragColor;

vec3 unlinearize(vec3 linear) {
    bvec3 cutoff = lessThanEqual(linear, vec3(0.0031308));
    vec3 higher = pow(linear, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear * vec3(12.92);
    return mix(higher, lower, cutoff);
}

void main() {
    vec4 p = texture(frame, gl_FragCoord.xy / dst_size);
    vec4 converted = vec4(0.0);
    if (p.a > 0.0) {
        vec3 c = clamp(p.rgb / p.a, vec3(0.0), vec3(1.0));
        converted = vec4(unlinearize(c) * p.a, p.a);
    }
    out_FragColor = vec4(dim.rgb * dim.a, dim.a) + converted * (1.0 - dim.a);
}
