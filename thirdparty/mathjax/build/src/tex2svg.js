// MathJax, set up to turn TeX into SVG without a browser: the lite adaptor
// stands in for the DOM. Bundled into one script that defines
// globalThis.tex2svg(tex, display) for the engine's MathJax module to call.
import { mathjax } from "mathjax-full/js/mathjax.js";
import { TeX } from "mathjax-full/js/input/tex.js";
import { SVG } from "mathjax-full/js/output/svg.js";
import { liteAdaptor } from "mathjax-full/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "mathjax-full/js/handlers/html.js";
import { AllPackages } from "mathjax-full/js/input/tex/AllPackages.js";

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);

// One document for every formula: making a new one per call leaks.
const document = mathjax.document("", {
	InputJax: new TeX({ packages: AllPackages }),
	OutputJax: new SVG({ fontCache: "local" }),
});

/// Returns the SVG for `tex`, as an <svg> element, or throws with the TeX error.
export default function tex2svg(tex, display) {
	const node = document.convert(tex, { display: !!display });
	const html = adaptor.outerHTML(node);
	document.clear();
	document.reset();
	const svg = html.match(/<svg[^>]*>[\s\S]*<\/svg>/)[0];
	if (svg.includes("data-mjx-error")) {
		throw new Error(svg.match(/title="([^"]*)"/)[1]);
	}
	return svg;
}
