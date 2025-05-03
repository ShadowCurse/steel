const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});
pub usingnamespace gl;
