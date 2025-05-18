const cgltf = @cImport({
    @cInclude("cgltf.h");
});
pub usingnamespace cgltf;

pub fn check_result(result: cgltf.cgltf_result) !void {
    return switch (result) {
        cgltf.cgltf_result_success => void{},
        cgltf.cgltf_result_data_too_short => error.cgltf_result_data_too_short,
        cgltf.cgltf_result_unknown_format => error.cgltf_result_unknown_format,
        cgltf.cgltf_result_invalid_json => error.cgltf_result_invalid_json,
        cgltf.cgltf_result_invalid_gltf => error.cgltf_result_invalid_gltf,
        cgltf.cgltf_result_invalid_options => error.cgltf_result_invalid_options,
        cgltf.cgltf_result_file_not_found => error.cgltf_result_file_not_found,
        cgltf.cgltf_result_io_error => error.cgltf_result_io_error,
        cgltf.cgltf_result_out_of_memory => error.cgltf_result_out_of_memory,
        cgltf.cgltf_result_legacy_gltf => error.cgltf_result_legacy_gltf,
        else => error.cgltf_unknown,
    };
}
