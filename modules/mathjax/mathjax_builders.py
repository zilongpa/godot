"""Functions used to generate source files during build time"""

import methods


def make_script_header(target, source, env):
    buffer = methods.get_buffer(str(source[0]))
    compressed = methods.compress_buffer(buffer)
    with methods.generated_wrapper(str(target[0])) as file:
        file.write(f"""\
inline constexpr int _tex2svg_script_size = {len(buffer)};
inline constexpr int _tex2svg_script_compressed_size = {len(compressed)};
inline constexpr unsigned char _tex2svg_script_compressed[] = {{
	{methods.format_buffer(compressed, 1)}
}};
""")
