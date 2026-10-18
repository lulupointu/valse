#version 440
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 mvp;
    vec4 params; // opacity, saturation, brightness, fullRange
};
layout(binding = 1) uniform sampler2D texY;
layout(binding = 2) uniform sampler2D texUV;

void main()
{
    float y = texture(texY, uv).r;
    vec2 c = texture(texUV, uv).rg - vec2(0.5);
    if (params.w < 0.5) {               // video range -> full range
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        c *= 255.0 / 224.0;
    }
    // BT.709 YCbCr -> RGB
    vec3 rgb = vec3(y + 1.5748 * c.y,
                    y - 0.1873 * c.x - 0.4681 * c.y,
                    y + 1.8556 * c.x);
    // color filter: brightness + saturation
    rgb += vec3(params.z);
    float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = clamp(mix(vec3(l), rgb, params.y), 0.0, 1.0);
    fragColor = vec4(rgb * params.x, params.x); // premultiplied
}
