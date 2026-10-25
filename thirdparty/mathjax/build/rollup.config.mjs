import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import terser from "@rollup/plugin-terser";

export default {
	input: "src/tex2svg.js",
	output: { file: "out/tex2svg.js", format: "iife", name: "tex2svg" },
	plugins: [resolve({ preferBuiltins: false }), commonjs(), terser({ format: { comments: false } })],
};
