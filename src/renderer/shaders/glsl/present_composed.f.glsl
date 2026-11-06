#version 430 core

// noctty divergence (#640): presents a frame whose alpha the window manager
// composes (Win32 blur-behind). With linear blending the target stores linear
// premultiplied color that the framebuffer sRGB-encodes per channel,
// srgb(c * a) with alpha a, while DWM composes sRGB-premultiplied pixels,
// srgb(c) * a. Sampling the sRGB texture decodes to c * a: divide a out,
// encode, and premultiply again. Written with GL_FRAMEBUFFER_SRGB off, so the
// bytes land as they are. An opaque pixel (a = 1) comes out unchanged.

layout(binding = 0) uniform sampler2D frame;
uniform vec2 dst_size;

layout(location = 0) out vec4 out_FragColor;

vec3 unlinearize(vec3 linear) {
    bvec3 cutoff = lessThanEqual(linear, vec3(0.0031308));
    vec3 higher = pow(linear, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear * vec3(12.92);
    return mix(higher, lower, cutoff);
}

void main() {
    vec4 p = texture(frame, gl_FragCoord.xy / dst_size);
    if (p.a <= 0.0) {
        out_FragColor = vec4(0.0);
        return;
    }
    vec3 c = clamp(p.rgb / p.a, vec3(0.0), vec3(1.0));
    out_FragColor = vec4(unlinearize(c) * p.a, p.a);
}
