#version 440
layout(location = 0) in vec2 pos;
layout(location = 0) out vec2 uv;
layout(std140, binding = 0) uniform buf {
    mat4 mvp;
    vec4 params; // opacity, saturation, brightness, fullRange
};
void main()
{
    uv = pos;
    gl_Position = mvp * vec4(pos, 0.0, 1.0);
}
