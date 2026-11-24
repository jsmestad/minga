defmodule Minga.RenderModel.UI.WhichKey do
  @moduledoc """
  The semantic which-key panel: where the leader sequence is, and what each next key does.

  The BEAM decides the words, the order and the sections; frontends decide how many columns a section takes to fit (docs/design/surfaces.md, docs/design/anatomy.md).

  * `path` is the formatted prefix (`"SPC a"`). It is the panel's identity: a click on a row or a breadcrumb names it, and the BEAM ignores a click whose path is no longer current.
  * `breadcrumb` has one crumb per key of the prefix, each with the group label it opened (`SPC`, then `a Minga`). A crumb's `path` is the prefix a click on it returns to.
  * `count` is the live count of the open group ("1 needs you"), drawn dim after the breadcrumb.
  * `hints` are the panel's own keys (`⌫ back`, `esc close`).
  * `entries` are in display order. Consecutive entries with the same `section` form one section; a section with an empty title has no heading.
  """

  @typedoc "What a row does: run a command, or open a group of more keys."
  @type kind :: :command | :group

  @typedoc """
  One row. `key` is the formatted key (`"a"`, `"SPC"`, `"C-s"`), and `codepoint` with `modifiers` is the raw key a click presses. `count` is the live count drawn dim after the label and `platform_key` the macOS ⌘ equivalent (`"⌘S"`); both are empty when there is none.
  """
  @type entry :: %{
          key: String.t(),
          codepoint: non_neg_integer(),
          modifiers: non_neg_integer(),
          label: String.t(),
          kind: kind(),
          section: String.t(),
          count: String.t(),
          platform_key: String.t()
        }

  @typedoc "One breadcrumb part: the key, the group label it opened, and the prefix a click on it returns to."
  @type crumb :: %{key: String.t(), label: String.t(), path: String.t()}

  @typedoc "A key the panel itself answers, such as `⌫ back`."
  @type hint :: %{key: String.t(), label: String.t()}

  @type t :: %__MODULE__{
          visible: boolean(),
          path: String.t(),
          breadcrumb: [crumb()],
          count: String.t(),
          hints: [hint()],
          entries: [entry()]
        }

  @enforce_keys [:visible]
  defstruct visible: false,
            path: "",
            breadcrumb: [],
            count: "",
            hints: [],
            entries: []
end
