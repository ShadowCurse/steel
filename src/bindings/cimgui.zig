const imgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cDefine("CIMGUI_USE_OPENGL3", "");
    @cDefine("CIMGUI_USE_SDL3", "");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
});
pub usingnamespace imgui;
