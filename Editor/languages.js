/* Fenced code block languages. SPEC.md §4.2.
 *
 * Every parser CodeMirror ships is vendored (scripts/vendor-codemirror.sh), which is ~3.5 MB of
 * JavaScript. Loading that into every note's web view would make opening a note slow for a feature
 * most notes never use, so nothing here is imported up front: each entry carries a `load` function
 * and CodeMirror's markdown parser calls it the first time a note actually contains a block in that
 * language, then re-parses. A note with no code blocks loads none of it.
 *
 * The dynamic imports use bare specifiers resolved by the import map in index.html, and they stay
 * on the pintack-app: scheme, which the page's CSP allows. Nothing is fetched from the network.
 */
import { LanguageDescription, LanguageSupport, StreamLanguage } from "@codemirror/language";

// A modern Lezer parser: @codemirror/lang-<pkg>, whose factory function is named `fn`.
const lang = (pkg, fn) => () => import(`@codemirror/lang-${pkg}`).then((m) => m[fn]());

// One of the ~100 legacy stream modes, which export a plain mode object. The LanguageSupport
// wrapper is not optional: lang-markdown reads `support.language.parser` off whatever load()
// resolves to, so handing it a bare Language throws and aborts the whole nested parse.
const legacy = (mode, exp) => () =>
  import(`@codemirror/legacy-modes/mode/${mode}`).then((m) => new LanguageSupport(StreamLanguage.define(m[exp])));

/* Each row: display name, aliases, icon, badge colour, loader.
 * The icon names a file in Editor/icons (vendored from Devicon by scripts/vendor-language-icons.sh).
 * Languages with no logo of their own use null and get a dot in the badge colour instead, so a
 * 100-language list still looks consistent. */
const TABLE = [
  ["PowerShell", ["powershell", "posh", "pwsh", "ps1"], "powershell", "#2b6bb0", legacy("powershell", "powerShell")],
  ["Shell", ["shell", "bash", "sh", "zsh", "console"], "shell", "#4d9a5f", legacy("shell", "shell")],
  ["Python", ["python", "py"], "python", "#3572a5", lang("python", "python")],
  ["JavaScript", ["javascript", "js", "node"], "javascript", "#f1e05a", lang("javascript", "javascript")],
  ["TypeScript", ["typescript", "ts"], "typescript", "#3178c6", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ typescript: true }))],
  ["JSX", ["jsx"], "react", "#61dafb", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true }))],
  ["TSX", ["tsx"], "react", "#3178c6", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true, typescript: true }))],
  ["JSON", ["json", "jsonc"], "json", "#cbcb41", lang("json", "json")],
  ["YAML", ["yaml", "yml"], "yaml", "#cb171e", lang("yaml", "yaml")],
  ["TOML", ["toml"], null, "#9c4221", legacy("toml", "toml")],
  ["INI", ["ini", "cfg", "conf", "properties"], null, "#6b6b73", legacy("properties", "properties")],
  ["SQL", ["sql", "mysql", "postgres", "postgresql", "tsql"], null, "#e38c00", lang("sql", "sql")],
  ["HTML", ["html", "htm"], "html", "#e34c26", lang("html", "html")],
  ["CSS", ["css"], "css", "#563d7c", lang("css", "css")],
  ["Sass", ["sass", "scss"], "sass", "#c76494", lang("sass", "sass")],
  ["Less", ["less"], null, "#1d365d", lang("less", "less")],
  ["XML", ["xml", "svg", "xsl", "plist"], "xml", "#005fa3", lang("xml", "xml")],
  ["Markdown", ["markdown", "md"], "markdown", "#6b6b73", () => import("@codemirror/lang-markdown").then((m) => m.markdown())],
  ["Swift", ["swift"], "swift", "#f05138", legacy("swift", "swift")],
  ["Go", ["go", "golang"], "go", "#00add8", lang("go", "go")],
  ["Rust", ["rust", "rs"], "rust", "#dea584", lang("rust", "rust")],
  ["Java", ["java"], "java", "#b07219", lang("java", "java")],
  ["C", ["c"], "c", "#555555", lang("cpp", "cpp")],
  ["C++", ["cpp", "c++", "cc", "hpp"], "cpp", "#f34b7d", lang("cpp", "cpp")],
  ["C#", ["csharp", "cs", "c#"], "csharp", "#178600", legacy("clike", "csharp")],
  ["Objective-C", ["objectivec", "objc"], "objectivec", "#438eff", legacy("clike", "objectiveC")],
  ["Kotlin", ["kotlin", "kt"], "kotlin", "#a97bff", legacy("clike", "kotlin")],
  ["Scala", ["scala"], "scala", "#c22d40", legacy("clike", "scala")],
  ["PHP", ["php"], "php", "#4f5d95", lang("php", "php")],
  ["Ruby", ["ruby", "rb"], "ruby", "#701516", legacy("ruby", "ruby")],
  ["Perl", ["perl", "pl"], "perl", "#0298c3", legacy("perl", "perl")],
  ["Lua", ["lua"], "lua", "#000080", legacy("lua", "lua")],
  ["R", ["r"], "r", "#198ce7", legacy("r", "r")],
  ["Julia", ["julia", "jl"], "julia", "#a270ba", legacy("julia", "julia")],
  ["MATLAB", ["matlab", "octave"], "matlab", "#e16737", legacy("octave", "octave")],
  ["Haskell", ["haskell", "hs"], "haskell", "#5e5086", legacy("haskell", "haskell")],
  ["Clojure", ["clojure", "clj"], "clojure", "#db5855", legacy("clojure", "clojure")],
  ["Lisp", ["lisp", "commonlisp", "elisp"], null, "#3fb68b", legacy("commonlisp", "commonLisp")],
  ["Scheme", ["scheme"], null, "#1e4aec", legacy("scheme", "scheme")],
  ["Erlang", ["erlang", "erl"], "erlang", "#b83998", legacy("erlang", "erlang")],
  ["Elixir", ["elixir", "ex"], "elixir", "#6e4a7e", legacy("ruby", "ruby")],
  ["Elm", ["elm"], "elm", "#60b5cc", legacy("elm", "elm")],
  ["Dart", ["dart"], "dart", "#00b4ab", legacy("clike", "dart")],
  ["Groovy", ["groovy", "gradle"], "groovy", "#4298b8", legacy("groovy", "groovy")],
  ["Visual Basic", ["vb", "vbnet", "vbscript"], "vb", "#945db7", legacy("vb", "vb")],
  ["Fortran", ["fortran", "f90"], "fortran", "#4d41b1", legacy("fortran", "fortran")],
  ["COBOL", ["cobol"], null, "#6b6b73", legacy("cobol", "cobol")],
  ["Pascal", ["pascal", "delphi"], null, "#e3f171", legacy("pascal", "pascal")],
  ["Assembly", ["asm", "assembly", "gas", "nasm"], null, "#6e4c13", legacy("gas", "gas")],
  ["Verilog", ["verilog", "systemverilog", "v"], null, "#b2b7f8", legacy("verilog", "verilog")],
  ["VHDL", ["vhdl"], null, "#adb2cb", legacy("vhdl", "vhdl")],
  ["Dockerfile", ["dockerfile", "docker"], "docker", "#384d54", legacy("dockerfile", "dockerFile")],
  ["NGINX", ["nginx"], "nginx", "#009639", legacy("nginx", "nginx")],
  ["CMake", ["cmake"], "cmake", "#da3434", legacy("cmake", "cmake")],
  ["Makefile", ["make", "makefile"], null, "#427819", legacy("shell", "shell")],
  ["Diff", ["diff", "patch"], null, "#88807b", legacy("diff", "diff")],
  ["HTTP", ["http"], null, "#005fa3", legacy("http", "http")],
  ["Gherkin", ["gherkin", "feature", "cucumber"], null, "#5b2063", legacy("gherkin", "gherkin")],
  ["GraphQL", ["graphql", "gql"], "graphql", "#e10098", legacy("javascript", "javascript")],
  ["Protobuf", ["protobuf", "proto"], null, "#4285f4", legacy("protobuf", "protobuf")],
  ["Turtle", ["turtle", "ttl", "sparql"], null, "#0c4597", legacy("turtle", "turtle")],
  ["Solidity", ["solidity", "sol"], "solidity", "#aa6746", legacy("clike", "c")],
  ["Puppet", ["puppet"], null, "#302b6d", legacy("puppet", "puppet")],
  ["Jinja", ["jinja", "jinja2", "j2", "twig"], null, "#a52a22", legacy("jinja2", "jinja2")],
  ["Liquid", ["liquid"], null, "#67b8de", lang("liquid", "liquid")],
  ["Vue", ["vue"], "vue", "#41b883", lang("vue", "vue")],
  ["Angular", ["angular"], "angular", "#dd0031", lang("angular", "angular")],
  ["WebAssembly", ["wast", "wat", "wasm"], null, "#04133b", lang("wast", "wast")],
  ["Stylus", ["stylus", "styl"], null, "#ff6347", legacy("stylus", "stylus")],
  ["CoffeeScript", ["coffeescript", "coffee"], "coffeescript", "#244776", legacy("coffeescript", "coffeeScript")],
  ["LiveScript", ["livescript", "ls"], null, "#499886", legacy("livescript", "liveScript")],
  ["Haxe", ["haxe", "hx"], "haxe", "#df7900", legacy("haxe", "haxe")],
  ["Crystal", ["crystal", "cr"], "crystal", "#000100", legacy("crystal", "crystal")],
  ["D", ["d"], null, "#ba595e", legacy("d", "d")],
  ["Tcl", ["tcl"], null, "#e4cc98", legacy("tcl", "tcl")],
  ["Smalltalk", ["smalltalk", "st"], null, "#596706", legacy("smalltalk", "smalltalk")],
  ["APL", ["apl"], null, "#5a8164", legacy("apl", "apl")],
  ["Forth", ["forth"], null, "#341708", legacy("forth", "forth")],
  ["Mathematica", ["mathematica", "wolfram"], null, "#dd1100", legacy("mathematica", "mathematica")],
  ["SAS", ["sas"], null, "#b34936", legacy("sas", "sas")],
  ["Stex", ["latex", "tex", "stex"], "latex", "#3d6117", legacy("stex", "stex")],
  ["Textile", ["textile"], null, "#6b6b73", legacy("textile", "textile")],
  ["Pug", ["pug", "jade"], null, "#a86454", legacy("pug", "pug")],
  ["Cypher", ["cypher"], null, "#008cc1", legacy("cypher", "cypher")],
  ["Z80", ["z80", "ez80"], null, "#6b6b73", legacy("z80", "z80")],
  ["Brainfuck", ["brainfuck", "bf"], null, "#2f2530", legacy("brainfuck", "brainfuck")],
];

/* The registry CodeMirror's markdown parser consults for ```<lang> blocks. */
export const codeLanguages = TABLE.map(([name, alias, , , load]) =>
  LanguageDescription.of({ name, alias, load }));

/* Badge lookup: every alias (and the display name) points at its row. */
const BY_ALIAS = new Map();
for (const [name, alias, icon, color] of TABLE) {
  const entry = { name, icon, color };
  BY_ALIAS.set(name.toLowerCase(), entry);
  for (const a of alias) BY_ALIAS.set(a.toLowerCase(), entry);
}

/** What to show in a fenced block's badge, or null for an unknown language. */
export function badgeFor(info) {
  const key = (info || "").trim().toLowerCase().split(/\s+/)[0];
  if (!key) return null;
  return BY_ALIAS.get(key) || { name: key, icon: null, color: "#6b6b73" };
}
