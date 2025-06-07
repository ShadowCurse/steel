const stb = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_truetype.h");
});

pub usingnamespace stb;
