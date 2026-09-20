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

/* Each row: display name, aliases, badge glyph, badge colour, loader.
 * The glyph is what shows in the badge on the block; the colour tints the badge dot for languages
 * with no obvious emoji, so a 100-language list still looks consistent. */
const TABLE = [
  ["PowerShell", ["powershell", "posh", "pwsh", "ps1"], "🔷", "#2b6bb0", legacy("powershell", "powerShell")],
  ["Shell", ["shell", "bash", "sh", "zsh", "console"], "🐚", "#4d9a5f", legacy("shell", "shell")],
  ["Python", ["python", "py"], "🐍", "#3572a5", lang("python", "python")],
  ["JavaScript", ["javascript", "js", "node"], "🟨", "#f1e05a", lang("javascript", "javascript")],
  ["TypeScript", ["typescript", "ts"], "🔵", "#3178c6", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ typescript: true }))],
  ["JSX", ["jsx"], "⚛️", "#61dafb", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true }))],
  ["TSX", ["tsx"], "⚛️", "#3178c6", () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true, typescript: true }))],
  ["JSON", ["json", "jsonc"], "📦", "#cbcb41", lang("json", "json")],
  ["YAML", ["yaml", "yml"], "⚙️", "#cb171e", lang("yaml", "yaml")],
  ["TOML", ["toml"], "⚙️", "#9c4221", legacy("toml", "toml")],
  ["INI", ["ini", "cfg", "conf", "properties"], "⚙️", "#6b6b73", legacy("properties", "properties")],
  ["SQL", ["sql", "mysql", "postgres", "postgresql", "tsql"], "🗄️", "#e38c00", lang("sql", "sql")],
  ["HTML", ["html", "htm"], "🌐", "#e34c26", lang("html", "html")],
  ["CSS", ["css"], "🎨", "#563d7c", lang("css", "css")],
  ["Sass", ["sass", "scss"], "🎨", "#c76494", lang("sass", "sass")],
  ["Less", ["less"], "🎨", "#1d365d", lang("less", "less")],
  ["XML", ["xml", "svg", "xsl", "plist"], "🌐", "#005fa3", lang("xml", "xml")],
  ["Markdown", ["markdown", "md"], "📝", "#6b6b73", () => import("@codemirror/lang-markdown").then((m) => m.markdown())],
  ["Swift", ["swift"], "🍎", "#f05138", legacy("swift", "swift")],
  ["Go", ["go", "golang"], "🐹", "#00add8", lang("go", "go")],
  ["Rust", ["rust", "rs"], "🦀", "#dea584", lang("rust", "rust")],
  ["Java", ["java"], "☕", "#b07219", lang("java", "java")],
  ["C", ["c"], "⚡", "#555555", lang("cpp", "cpp")],
  ["C++", ["cpp", "c++", "cc", "hpp"], "⚡", "#f34b7d", lang("cpp", "cpp")],
  ["C#", ["csharp", "cs", "c#"], "⚡", "#178600", legacy("clike", "csharp")],
  ["Objective-C", ["objectivec", "objc"], "⚡", "#438eff", legacy("clike", "objectiveC")],
  ["Kotlin", ["kotlin", "kt"], "🟣", "#a97bff", legacy("clike", "kotlin")],
  ["Scala", ["scala"], "🔴", "#c22d40", legacy("clike", "scala")],
  ["PHP", ["php"], "🐘", "#4f5d95", lang("php", "php")],
  ["Ruby", ["ruby", "rb"], "💎", "#701516", legacy("ruby", "ruby")],
  ["Perl", ["perl", "pl"], "🐪", "#0298c3", legacy("perl", "perl")],
  ["Lua", ["lua"], "🌙", "#000080", legacy("lua", "lua")],
  ["R", ["r"], "📊", "#198ce7", legacy("r", "r")],
  ["Julia", ["julia", "jl"], "📊", "#a270ba", legacy("julia", "julia")],
  ["MATLAB", ["matlab", "octave"], "📊", "#e16737", legacy("octave", "octave")],
  ["Haskell", ["haskell", "hs"], "λ", "#5e5086", legacy("haskell", "haskell")],
  ["Clojure", ["clojure", "clj"], "λ", "#db5855", legacy("clojure", "clojure")],
  ["Lisp", ["lisp", "commonlisp", "elisp"], "λ", "#3fb68b", legacy("commonlisp", "commonLisp")],
  ["Scheme", ["scheme"], "λ", "#1e4aec", legacy("scheme", "scheme")],
  ["Erlang", ["erlang", "erl"], "📡", "#b83998", legacy("erlang", "erlang")],
  ["Elixir", ["elixir", "ex"], "💧", "#6e4a7e", legacy("ruby", "ruby")],
  ["Elm", ["elm"], "🌳", "#60b5cc", legacy("elm", "elm")],
  ["Dart", ["dart"], "🎯", "#00b4ab", legacy("clike", "dart")],
  ["Groovy", ["groovy", "gradle"], "🅖", "#4298b8", legacy("groovy", "groovy")],
  ["Visual Basic", ["vb", "vbnet", "vbscript"], "🟦", "#945db7", legacy("vb", "vb")],
  ["Fortran", ["fortran", "f90"], "🔢", "#4d41b1", legacy("fortran", "fortran")],
  ["COBOL", ["cobol"], "🏛️", "#6b6b73", legacy("cobol", "cobol")],
  ["Pascal", ["pascal", "delphi"], "🔺", "#e3f171", legacy("pascal", "pascal")],
  ["Assembly", ["asm", "assembly", "gas", "nasm"], "🔧", "#6e4c13", legacy("gas", "gas")],
  ["Verilog", ["verilog", "systemverilog", "v"], "🔌", "#b2b7f8", legacy("verilog", "verilog")],
  ["VHDL", ["vhdl"], "🔌", "#adb2cb", legacy("vhdl", "vhdl")],
  ["Dockerfile", ["dockerfile", "docker"], "🐳", "#384d54", legacy("dockerfile", "dockerFile")],
  ["NGINX", ["nginx"], "🔧", "#009639", legacy("nginx", "nginx")],
  ["CMake", ["cmake"], "🔧", "#da3434", legacy("cmake", "cmake")],
  ["Makefile", ["make", "makefile"], "🔧", "#427819", legacy("shell", "shell")],
  ["Diff", ["diff", "patch"], "±", "#88807b", legacy("diff", "diff")],
  ["HTTP", ["http"], "📡", "#005fa3", legacy("http", "http")],
  ["Gherkin", ["gherkin", "feature", "cucumber"], "🥒", "#5b2063", legacy("gherkin", "gherkin")],
  ["GraphQL", ["graphql", "gql"], "🔗", "#e10098", legacy("javascript", "javascript")],
  ["Protobuf", ["protobuf", "proto"], "📦", "#4285f4", legacy("protobuf", "protobuf")],
  ["Turtle", ["turtle", "ttl", "sparql"], "🐢", "#0c4597", legacy("turtle", "turtle")],
  ["Solidity", ["solidity", "sol"], "⛓️", "#aa6746", legacy("clike", "c")],
  ["Puppet", ["puppet"], "🎭", "#302b6d", legacy("puppet", "puppet")],
  ["Jinja", ["jinja", "jinja2", "j2", "twig"], "🧩", "#a52a22", legacy("jinja2", "jinja2")],
  ["Liquid", ["liquid"], "🧩", "#67b8de", lang("liquid", "liquid")],
  ["Vue", ["vue"], "🟩", "#41b883", lang("vue", "vue")],
  ["Angular", ["angular"], "🅰️", "#dd0031", lang("angular", "angular")],
  ["WebAssembly", ["wast", "wat", "wasm"], "⚡", "#04133b", lang("wast", "wast")],
  ["Stylus", ["stylus", "styl"], "🎨", "#ff6347", legacy("stylus", "stylus")],
  ["CoffeeScript", ["coffeescript", "coffee"], "☕", "#244776", legacy("coffeescript", "coffeeScript")],
  ["LiveScript", ["livescript", "ls"], "☕", "#499886", legacy("livescript", "liveScript")],
  ["Haxe", ["haxe", "hx"], "🎮", "#df7900", legacy("haxe", "haxe")],
  ["Crystal", ["crystal", "cr"], "💠", "#000100", legacy("crystal", "crystal")],
  ["D", ["d"], "🇩", "#ba595e", legacy("d", "d")],
  ["Tcl", ["tcl"], "🔧", "#e4cc98", legacy("tcl", "tcl")],
  ["Smalltalk", ["smalltalk", "st"], "💬", "#596706", legacy("smalltalk", "smalltalk")],
  ["APL", ["apl"], "🔣", "#5a8164", legacy("apl", "apl")],
  ["Forth", ["forth"], "🔣", "#341708", legacy("forth", "forth")],
  ["Mathematica", ["mathematica", "wolfram"], "🔢", "#dd1100", legacy("mathematica", "mathematica")],
  ["SAS", ["sas"], "📊", "#b34936", legacy("sas", "sas")],
  ["Stex", ["latex", "tex", "stex"], "📐", "#3d6117", legacy("stex", "stex")],
  ["Textile", ["textile"], "📝", "#6b6b73", legacy("textile", "textile")],
  ["Pug", ["pug", "jade"], "🐶", "#a86454", legacy("pug", "pug")],
  ["Cypher", ["cypher"], "🔗", "#008cc1", legacy("cypher", "cypher")],
  ["Z80", ["z80", "ez80"], "🔧", "#6b6b73", legacy("z80", "z80")],
  ["Brainfuck", ["brainfuck", "bf"], "🧠", "#2f2530", legacy("brainfuck", "brainfuck")],
];

/* The registry CodeMirror's markdown parser consults for ```<lang> blocks. */
export const codeLanguages = TABLE.map(([name, alias, , , load]) =>
  LanguageDescription.of({ name, alias, load }));

/* Badge lookup: every alias (and the display name) points at its row. */
const BY_ALIAS = new Map();
for (const [name, alias, glyph, color] of TABLE) {
  const entry = { name, glyph, color };
  BY_ALIAS.set(name.toLowerCase(), entry);
  for (const a of alias) BY_ALIAS.set(a.toLowerCase(), entry);
}

/** What to show in a fenced block's badge, or null for an unknown language. */
export function badgeFor(info) {
  const key = (info || "").trim().toLowerCase().split(/\s+/)[0];
  if (!key) return null;
  return BY_ALIAS.get(key) || { name: key, glyph: "", color: "#6b6b73" };
}
