defmodule Minga.Agent.CodeHighlight do
  @moduledoc """
  Regex-based syntax highlighter for code blocks in agent chat.

  Provides lightweight highlighting for code blocks rendered in the chat
  panel. Uses regex patterns to identify keywords, strings, comments,
  numbers, and other token types for common programming languages.

  This is intentionally simpler than the tree-sitter highlighting used
  for open file buffers. It handles the 80% case for LLM output without
  the complexity of sending ephemeral parse requests through the Zig
  parser Port.

  ## Supported languages

  Elixir, JavaScript/TypeScript, Python, Ruby, Rust, Go, Zig, Bash/Shell,
  HTML, CSS, SQL, JSON, YAML, Lua, C/C++.

  ## Output format

  Returns a list of `{text, capture_name}` segments per line, where
  `capture_name` is a tree-sitter-compatible capture name string that
  maps to the theme's syntax color map via `Theme.style_for_capture/2`.
  """

  @typedoc "A highlighted text segment: {text, capture_name}."
  @type segment :: {String.t(), String.t()}

  @typedoc "Language identifier (lowercase string from fence tag)."
  @type language :: String.t()

  @doc """
  Returns true if the given language has highlighting support.
  """
  @spec supported?(language()) :: boolean()
  def supported?(lang) when is_binary(lang) do
    Map.has_key?(language_rules(), normalize_lang(lang))
  end

  @doc """
  Highlights a single line of code for the given language.

  Returns a list of `{text, capture_name}` segments. If the language
  is not supported, returns `[{line, ""}]` (plain text, no capture).

  The capture names are tree-sitter-compatible strings that map directly
  to the theme's syntax color map (e.g., "keyword", "string", "comment",
  "function", "type", "number", "operator").
  """
  @spec highlight_line(String.t(), language()) :: [segment()]
  def highlight_line(line, lang) when is_binary(line) and is_binary(lang) do
    normalized = normalize_lang(lang)

    case Map.get(language_rules(), normalized) do
      nil -> [{line, ""}]
      rules -> tokenize(line, rules)
    end
  end

  @doc """
  Returns the list of supported language identifiers.
  """
  @spec supported_languages() :: [language()]
  def supported_languages do
    Map.keys(language_rules())
  end

  # ── Language normalization ───────────────────────────────────────────────

  @lang_aliases %{
    "js" => "javascript",
    "jsx" => "javascript",
    "ts" => "typescript",
    "tsx" => "typescript",
    "sh" => "bash",
    "shell" => "bash",
    "zsh" => "bash",
    "rb" => "ruby",
    "rs" => "rust",
    "py" => "python",
    "ex" => "elixir",
    "exs" => "elixir",
    "eex" => "elixir",
    "heex" => "elixir",
    "yml" => "yaml",
    "c++" => "cpp",
    "h" => "c",
    "hpp" => "cpp"
  }

  @spec normalize_lang(String.t()) :: String.t()
  defp normalize_lang(lang) do
    normalized = String.downcase(String.trim(lang))
    Map.get(@lang_aliases, normalized, normalized)
  end

  # ── Tokenizer ───────────────────────────────────────────────────────────

  @typedoc "A tokenization rule: {regex, capture_name}."
  @type rule :: {Regex.t(), String.t()}

  @spec tokenize(String.t(), [rule()]) :: [segment()]
  defp tokenize("", _rules), do: []

  defp tokenize(text, rules) do
    case find_earliest_match(text, rules) do
      nil ->
        [{text, ""}]

      {0, match_text, capture} ->
        rest = String.slice(text, String.length(match_text)..-1//1)
        [{match_text, capture} | tokenize(rest, rules)]

      {offset, match_text, capture} ->
        before = String.slice(text, 0, offset)
        rest = String.slice(text, (offset + String.length(match_text))..-1//1)
        [{before, ""}, {match_text, capture} | tokenize(rest, rules)]
    end
  end

  @spec find_earliest_match(String.t(), [rule()]) ::
          {non_neg_integer(), String.t(), String.t()} | nil
  defp find_earliest_match(text, rules) do
    Enum.reduce(rules, nil, fn {regex, capture}, best ->
      case Regex.run(regex, text, return: :index) do
        [{start, len} | _] ->
          match_text = String.slice(text, start, len)
          choose_best_match(best, {start, match_text, capture})

        _ ->
          best
      end
    end)
  end

  @spec choose_best_match(
          {non_neg_integer(), String.t(), String.t()} | nil,
          {non_neg_integer(), String.t(), String.t()}
        ) :: {non_neg_integer(), String.t(), String.t()}
  defp choose_best_match(nil, match), do: match

  defp choose_best_match({best_start, _, _} = best, {start, _, _}) when start > best_start,
    do: best

  defp choose_best_match({best_start, best_text, _} = best, {start, match_text, _} = match)
       when start == best_start do
    if String.length(match_text) > String.length(best_text), do: match, else: best
  end

  defp choose_best_match(_best, match), do: match

  # ── Language rule definitions ───────────────────────────────────────────

  @spec language_rules() :: %{String.t() => [rule()]}
  defp language_rules do
    %{
      "elixir" => elixir_rules(),
      "javascript" => javascript_rules(),
      "typescript" => typescript_rules(),
      "python" => python_rules(),
      "ruby" => ruby_rules(),
      "rust" => rust_rules(),
      "go" => go_rules(),
      "zig" => zig_rules(),
      "bash" => bash_rules(),
      "html" => html_rules(),
      "css" => css_rules(),
      "sql" => sql_rules(),
      "json" => json_rules(),
      "yaml" => yaml_rules(),
      "lua" => lua_rules(),
      "c" => c_rules(),
      "cpp" => cpp_rules()
    }
  end

  # ── Elixir ──────────────────────────────────────────────────────────────

  @spec elixir_rules() :: [rule()]
  defp elixir_rules do
    [
      # Comments must come first
      {~r/#.*/, "comment"},
      # Strings (double-quoted, heredoc-aware single line)
      {~r/"""[\s\S]*?"""/, "string"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      # Sigils
      {~r/~[a-zA-Z](?:\((?:[^)\\]|\\.)*\)|\[(?:[^\]\\]|\\.)*\]|\{(?:[^}\\]|\\.)*\}|<(?:[^>\\]|\\.)*>|\/(?:[^\/\\]|\\.)*\/|\|(?:[^|\\]|\\.)*\||"(?:[^"\\]|\\.)*")[a-zA-Z]*/,
       "string.special"},
      # Atoms
      {~r/:[a-zA-Z_][a-zA-Z0-9_]*[?!]?/, "string.special.symbol"},
      # Module names
      {~r/[A-Z][a-zA-Z0-9_.]*/, "type"},
      # Numbers
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d[\d_]*\.\d[\d_]*(?:[eE][+-]?\d+)?/, "number"},
      {~r/\d[\d_]*/, "number"},
      # Keywords (word boundary via \b)
      {~r/\b(?:def|defp|defmodule|defmacro|defmacrop|defstruct|defimpl|defprotocol|defguard|defguardp|defdelegate|defoverridable|defexception|do|end|fn|case|cond|if|else|unless|when|with|for|try|catch|rescue|after|raise|reraise|throw|quote|unquote|require|alias|import|use|in|not|and|or|true|false|nil|is_atom|is_binary|is_boolean|is_float|is_function|is_integer|is_list|is_map|is_nil|is_number|is_pid|is_port|is_reference|is_tuple)\b/,
       "keyword"},
      # Function calls
      {~r/[a-z_][a-zA-Z0-9_]*[?!]?(?=\()/, "function.call"},
      # Operators
      {~r/(?:\|>|<>|\+\+|--|<-|->|=>|\|\||&&|==|!=|<=|>=|=~|~~~|\.\.\.|\.\.|\.(?=[a-z_]))/,
       "operator"},
      {~r/[+\-*\/=<>|&^~!@]/, "operator"},
      # Special variables
      {~r/\b(?:__MODULE__|__DIR__|__ENV__|__CALLER__|__STACKTRACE__)\b/, "variable.builtin"},
      # Capture operator
      {~r/&\d+/, "variable.builtin"}
    ]
  end

  # ── JavaScript ──────────────────────────────────────────────────────────

  @spec javascript_rules() :: [rule()]
  defp javascript_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/`(?:[^`\\]|\\.)*`/, "string"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d+\.\d+(?:[eE][+-]?\d+)?/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|enum|export|extends|finally|for|from|function|if|implements|import|in|instanceof|interface|let|new|of|package|private|protected|public|return|static|super|switch|this|throw|try|typeof|var|void|while|with|yield|true|false|null|undefined)\b/,
       "keyword"},
      {~r/[a-zA-Z_$][a-zA-Z0-9_$]*(?=\()/, "function.call"},
      {~r/(?:=>|===|!==|==|!=|<=|>=|&&|\|\||\?\?|\?\.|\.\.\.)|[+\-*\/%=<>!&|^~?]/, "operator"}
    ]
  end

  # ── TypeScript ──────────────────────────────────────────────────────────

  @spec typescript_rules() :: [rule()]
  defp typescript_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/`(?:[^`\\]|\\.)*`/, "string"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d+\.\d+(?:[eE][+-]?\d+)?/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:abstract|as|async|await|break|case|catch|class|const|continue|debugger|declare|default|delete|do|else|enum|export|extends|finally|for|from|function|get|if|implements|import|in|infer|instanceof|interface|is|keyof|let|module|namespace|new|of|package|private|protected|public|readonly|return|satisfies|set|static|super|switch|this|throw|try|type|typeof|unique|var|void|while|with|yield|true|false|null|undefined|never|unknown|any|string|number|boolean|symbol|bigint|object)\b/,
       "keyword"},
      {~r/[A-Z][a-zA-Z0-9_]*/, "type"},
      {~r/[a-zA-Z_$][a-zA-Z0-9_$]*(?=\()/, "function.call"},
      {~r/(?:=>|===|!==|==|!=|<=|>=|&&|\|\||\?\?|\?\.|\.\.\.)|[+\-*\/%=<>!&|^~?]/, "operator"}
    ]
  end

  # ── Python ──────────────────────────────────────────────────────────────

  @spec python_rules() :: [rule()]
  defp python_rules do
    [
      {~r/#.*/, "comment"},
      {~r/"""[\s\S]*?"""/, "string"},
      {~r/'''[\s\S]*?'''/, "string"},
      {~r/f"(?:[^"\\]|\\.)*"/, "string.special"},
      {~r/f'(?:[^'\\]|\\.)*'/, "string.special"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d+\.\d+(?:[eE][+-]?\d+)?/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|True|False|None)\b/,
       "keyword"},
      {~r/\b(?:int|float|str|bool|list|dict|tuple|set|bytes|type|object|Exception)\b/,
       "type.builtin"},
      {~r/@[a-zA-Z_][a-zA-Z0-9_]*/, "function.macro"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:->|:=|==|!=|<=|>=|\*\*|\|\|)|[+\-*\/%=<>!&|^~@]/, "operator"}
    ]
  end

  # ── Ruby ────────────────────────────────────────────────────────────────

  @spec ruby_rules() :: [rule()]
  defp ruby_rules do
    [
      {~r/#.*/, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/:[a-zA-Z_][a-zA-Z0-9_]*[?!]?/, "string.special.symbol"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d+\.\d+/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:alias|and|begin|break|case|class|def|defined\?|do|else|elsif|end|ensure|extend|for|if|in|include|module|next|nil|not|or|prepend|raise|redo|require|rescue|retry|return|self|super|then|unless|until|when|while|yield|true|false|attr_accessor|attr_reader|attr_writer|private|protected|public)\b/,
       "keyword"},
      {~r/[A-Z][a-zA-Z0-9_]*/, "type"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*[?!]?(?=\s*[({])/, "function.call"},
      {~r/(?:=>|<=>|==|!=|<=|>=|&&|\|\||\.\.|\.\.\.)|[+\-*\/%=<>!&|^~]/, "operator"}
    ]
  end

  # ── Rust ────────────────────────────────────────────────────────────────

  @spec rust_rules() :: [rule()]
  defp rust_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)'/, "character"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d[\d_]*\.\d[\d_]*(?:[eE][+-]?\d+)?(?:f32|f64)?/, "number"},
      {~r/\d[\d_]*(?:u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize)?/, "number"},
      {~r/\b(?:as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|type|union|unsafe|use|where|while|true|false)\b/,
       "keyword"},
      {~r/\b(?:bool|char|f32|f64|i8|i16|i32|i64|i128|isize|str|u8|u16|u32|u64|u128|usize|String|Vec|Option|Result|Box|Rc|Arc|HashMap|HashSet)\b/,
       "type.builtin"},
      {~r/#\[.*?\]/, "function.macro"},
      {~r/[a-z_][a-zA-Z0-9_]*!/, "function.macro"},
      {~r/[A-Z][a-zA-Z0-9_]*/, "type"},
      {~r/[a-z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:=>|->|::|==|!=|<=|>=|&&|\|\||\.\.|\.\.=)|[+\-*\/%=<>!&|^~?]/, "operator"}
    ]
  end

  # ── Go ──────────────────────────────────────────────────────────────────

  @spec go_rules() :: [rule()]
  defp go_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/`[^`]*`/, "string"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "character"},
      {~r/0[xXoObB][0-9a-fA-F_]+/, "number"},
      {~r/\d+\.\d+(?:[eE][+-]?\d+)?/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|true|false|nil|iota)\b/,
       "keyword"},
      {~r/\b(?:bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr|any)\b/,
       "type.builtin"},
      {~r/[A-Z][a-zA-Z0-9_]*/, "type"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?::=|<-|==|!=|<=|>=|&&|\|\||\.\.\.)|[+\-*\/%=<>!&|^~]/, "operator"}
    ]
  end

  # ── Zig ────────────────────────────────────────────────────────────────

  @spec zig_rules() :: [rule()]
  defp zig_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)'/, "character"},
      {~r/0[xX][0-9a-fA-F_]+/, "number"},
      {~r/\d[\d_]*\.\d[\d_]*/, "number"},
      {~r/\d[\d_]*/, "number"},
      {~r/\b(?:align|allowzero|and|asm|async|await|break|callconv|catch|comptime|const|continue|defer|else|enum|errdefer|error|export|extern|fn|for|if|inline|linksection|noalias|nosuspend|opaque|or|orelse|packed|pub|resume|return|struct|suspend|switch|test|threadlocal|try|union|unreachable|var|volatile|while)\b/,
       "keyword"},
      {~r/\b(?:bool|void|noreturn|type|anyerror|anyframe|anytype|anyopaque|comptime_int|comptime_float|[iu]\d+|f16|f32|f64|f80|f128|usize|isize)\b/,
       "type.builtin"},
      {~r/@[a-zA-Z_][a-zA-Z0-9_]*/, "function.builtin"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:=>|==|!=|<=|>=|\+\+|\*\*)|[+\-*\/%=<>!&|^~]/, "operator"}
    ]
  end

  # ── Bash/Shell ──────────────────────────────────────────────────────────

  @spec bash_rules() :: [rule()]
  defp bash_rules do
    [
      {~r/#.*/, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'[^']*'/, "string"},
      {~r/\$\{[^}]*\}/, "variable.builtin"},
      {~r/\$[a-zA-Z_][a-zA-Z0-9_]*/, "variable.builtin"},
      {~r/\d+/, "number"},
      {~r/\b(?:if|then|else|elif|fi|case|esac|for|while|until|do|done|in|function|select|time|coproc|return|exit|break|continue|source|export|unset|readonly|declare|local|typeset|eval|exec|trap|set|shift)\b/,
       "keyword"},
      {~r/\b(?:echo|printf|read|cd|pwd|ls|cat|grep|sed|awk|find|sort|uniq|wc|head|tail|cut|tr|xargs|tee|test|true|false)\b/,
       "function.builtin"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:&&|\|\||>>|<<|;;)|[|<>&;]/, "operator"}
    ]
  end

  # ── HTML ────────────────────────────────────────────────────────────────

  @spec html_rules() :: [rule()]
  defp html_rules do
    [
      {~r/<!--[\s\S]*?-->/, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/<\/?[a-zA-Z][a-zA-Z0-9-]*/, "keyword"},
      {~r/\b[a-zA-Z-]+(?==)/, "variable.parameter"},
      {~r/[<>\/=]/, "operator"}
    ]
  end

  # ── CSS ────────────────────────────────────────────────────────────────

  @spec css_rules() :: [rule()]
  defp css_rules do
    [
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/#[0-9a-fA-F]{3,8}/, "number"},
      {~r/\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|ch|ex|cm|mm|in|pt|pc|s|ms|deg|rad|turn)?/,
       "number"},
      {~r/@(?:media|import|keyframes|font-face|supports|charset|namespace|layer|container|property|scope)\b/,
       "keyword"},
      {~r/\b(?:inherit|initial|unset|revert|none|auto|normal)\b/, "keyword"},
      {~r/\.[a-zA-Z_-][a-zA-Z0-9_-]*/, "type"},
      {~r/#[a-zA-Z_-][a-zA-Z0-9_-]*(?![0-9a-fA-F])/, "function"},
      {~r/[a-zA-Z-]+(?=\s*:)/, "variable.parameter"},
      {~r/[{}:;,>+~]/, "operator"}
    ]
  end

  # ── SQL ────────────────────────────────────────────────────────────────

  @spec sql_rules() :: [rule()]
  defp sql_rules do
    [
      {~r/--.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/\d+\.\d+/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TABLE|INDEX|VIEW|INTO|VALUES|SET|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|ON|AND|OR|NOT|IN|EXISTS|BETWEEN|LIKE|IS|NULL|AS|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END|BEGIN|COMMIT|ROLLBACK|TRANSACTION|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|CHECK|UNIQUE|CASCADE|GRANT|REVOKE|WITH|RECURSIVE|RETURNING|EXCEPT|INTERSECT|select|from|where|insert|update|delete|create|drop|alter|table|index|view|into|values|set|join|left|right|inner|outer|cross|on|and|or|not|in|exists|between|like|is|null|as|order|by|group|having|limit|offset|union|all|distinct|case|when|then|else|end|begin|commit|rollback|transaction|primary|key|foreign|references|constraint|default|check|unique|cascade|grant|revoke|with|recursive|returning|except|intersect)\b/,
       "keyword"},
      {~r/\b(?:INTEGER|TEXT|REAL|BLOB|BOOLEAN|VARCHAR|CHAR|INT|BIGINT|SMALLINT|DECIMAL|NUMERIC|FLOAT|DOUBLE|DATE|TIME|TIMESTAMP|SERIAL|UUID|JSONB|JSON|ARRAY|integer|text|real|blob|boolean|varchar|char|int|bigint|smallint|decimal|numeric|float|double|date|time|timestamp|serial|uuid|jsonb|json|array)\b/,
       "type.builtin"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/[=<>!]+|[+\-*\/%]/, "operator"}
    ]
  end

  # ── JSON ────────────────────────────────────────────────────────────────

  @spec json_rules() :: [rule()]
  defp json_rules do
    [
      {~r/"(?:[^"\\]|\\.)*"(?=\s*:)/, "string.special.key"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/-?\d+\.\d+(?:[eE][+-]?\d+)?/, "number"},
      {~r/-?\d+/, "number"},
      {~r/\b(?:true|false|null)\b/, "keyword"},
      {~r/[{}\[\]:,]/, "operator"}
    ]
  end

  # ── YAML ────────────────────────────────────────────────────────────────

  @spec yaml_rules() :: [rule()]
  defp yaml_rules do
    [
      {~r/#.*/, "comment"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'[^']*'/, "string"},
      {~r/\d+\.\d+/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:true|false|null|yes|no|on|off)\b/i, "keyword"},
      {~r/[a-zA-Z_][a-zA-Z0-9_.-]*(?=\s*:)/, "string.special.key"},
      {~r/[:\-|>]/, "operator"}
    ]
  end

  # ── Lua ────────────────────────────────────────────────────────────────

  @spec lua_rules() :: [rule()]
  defp lua_rules do
    [
      {~r/--\[\[[\s\S]*?\]\]/, "comment"},
      {~r/--.*/, "comment"},
      {~r/\[\[[\s\S]*?\]\]/, "string"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)*'/, "string"},
      {~r/0[xX][0-9a-fA-F]+/, "number"},
      {~r/\d+\.\d+/, "number"},
      {~r/\d+/, "number"},
      {~r/\b(?:and|break|do|else|elseif|end|for|function|goto|if|in|local|not|or|repeat|return|then|until|while|true|false|nil)\b/,
       "keyword"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:==|~=|<=|>=|\.\.|\.\.\.|::)|[+\-*\/%^#<>=]/, "operator"}
    ]
  end

  # ── C ──────────────────────────────────────────────────────────────────

  @spec c_rules() :: [rule()]
  defp c_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/#\s*(?:include|define|undef|ifdef|ifndef|if|elif|else|endif|error|warning|pragma)\b.*/,
       "keyword.directive"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)'/, "character"},
      {~r/0[xX][0-9a-fA-F]+[uUlL]*/, "number"},
      {~r/\d+\.\d+[fFlL]?/, "number"},
      {~r/\d+[uUlL]*/, "number"},
      {~r/\b(?:auto|break|case|const|continue|default|do|else|enum|extern|for|goto|if|inline|register|restrict|return|sizeof|static|struct|switch|typedef|union|volatile|while|_Alignas|_Alignof|_Atomic|_Bool|_Complex|_Generic|_Imaginary|_Noreturn|_Static_assert|_Thread_local)\b/,
       "keyword"},
      {~r/\b(?:void|char|short|int|long|float|double|signed|unsigned|size_t|ssize_t|ptrdiff_t|intptr_t|uintptr_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|bool|FILE|NULL)\b/,
       "type.builtin"},
      {~r/[A-Z][A-Z0-9_]*\b/, "constant"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:->|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|--)|[+\-*\/%=<>!&|^~?]/, "operator"}
    ]
  end

  # ── C++ ─────────────────────────────────────────────────────────────────

  @spec cpp_rules() :: [rule()]
  defp cpp_rules do
    [
      {~r/\/\/.*/, "comment"},
      {~r/\/\*[\s\S]*?\*\//, "comment"},
      {~r/#\s*(?:include|define|undef|ifdef|ifndef|if|elif|else|endif|error|warning|pragma)\b.*/,
       "keyword.directive"},
      {~r/"(?:[^"\\]|\\.)*"/, "string"},
      {~r/'(?:[^'\\]|\\.)'/, "character"},
      {~r/0[xX][0-9a-fA-F]+[uUlL]*/, "number"},
      {~r/\d+\.\d+[fFlL]?/, "number"},
      {~r/\d+[uUlL]*/, "number"},
      {~r/\b(?:alignas|alignof|and|and_eq|asm|auto|bitand|bitor|break|case|catch|class|compl|concept|const|const_cast|consteval|constexpr|constinit|continue|co_await|co_return|co_yield|decltype|default|delete|do|dynamic_cast|else|enum|explicit|export|extern|for|friend|goto|if|inline|mutable|namespace|new|noexcept|not|not_eq|operator|or|or_eq|private|protected|public|register|reinterpret_cast|requires|return|sizeof|static|static_assert|static_cast|struct|switch|template|this|thread_local|throw|try|typedef|typeid|typename|union|using|virtual|volatile|while|xor|xor_eq|true|false|nullptr)\b/,
       "keyword"},
      {~r/\b(?:void|char|short|int|long|float|double|signed|unsigned|bool|wchar_t|char8_t|char16_t|char32_t|auto|size_t|string|vector|map|set|unique_ptr|shared_ptr|weak_ptr|optional|variant|any|tuple|array|span)\b/,
       "type.builtin"},
      {~r/[A-Z][a-zA-Z0-9_]*/, "type"},
      {~r/[a-zA-Z_][a-zA-Z0-9_]*(?=\()/, "function.call"},
      {~r/(?:->|::|=>|==|!=|<=|>=|&&|\|\||<<|>>|<=>|\+\+|--|\.\*|->\*)|[+\-*\/%=<>!&|^~?]/,
       "operator"}
    ]
  end
end
