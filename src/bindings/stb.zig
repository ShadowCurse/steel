const stb = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_truetype.h");
    @cDefine("STB_VORBIS_HEADER_ONLY", "");
    @cInclude("stb_vorbis.h");
});

pub usingnamespace stb;
