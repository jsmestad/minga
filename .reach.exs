# Reach architecture policy (`mix reach.check --arch`, about 12s).
#
# Layer direction stays in `Minga.Credo.DependencyDirectionCheck` (EX9001); it owns global Layer 0/1/2 and Agent-internal level classification. This file holds runtime effect contracts for pure foundations and explicit pure Agent values, plus deleted architecture that must not return.
#
# Reach 2.8.4 can activate Ecto/Phoenix plugins from docstrings and then misclassify unrelated local calls as writes (https://github.com/elixir-vibe/reach/issues/46). To check for accidental activation, run `mix run --no-start -e 'IO.inspect(Reach.Plugin.Inference.infer(Path.wildcard("lib/**/*.ex")))'` and look for Ecto or Phoenix, not an empty plugin list.
# Global prefixes mirror Credo's layer_0_prefixes/0. Transcript is an explicit
# Agent-internal Level 0 contract, not a global Layer 0 foundation.
pure_prefixes = [
  "Minga.Buffer.ChangeLog",
  "Minga.Buffer.ConflictIndex",
  "Minga.Buffer.Cursor",
  "Minga.Buffer.Document",
  "Minga.Buffer.EditDelta",
  "Minga.Buffer.EditSource",
  "Minga.Buffer.FileMutation",
  "Minga.Buffer.Lines",
  "Minga.Buffer.Position",
  "Minga.Buffer.RenderSnapshot",
  "Minga.Buffer.SaveState",
  "Minga.Buffer.Selection",
  "Minga.Buffer.Span",
  "Minga.Buffer.State",
  "Minga.Buffer.UndoHistory",
  "Minga.Buffer.UndoPatch",
  "Minga.Editing.Motion",
  "Minga.Editing.Operator",
  "Minga.Editing.TextObject",
  "Minga.Editing.Search",
  "Minga.Editing.AutoPair",
  "Minga.Editing.Comment",
  "Minga.Editing.Text.Readable",
  "Minga.Editing.NavigableContent",
  "Minga.Editing.Scroll",
  "Minga.Editing.Fold.Range",
  "Minga.Editing.Model",
  "Minga.Core",
  "Minga.Mode",
  "Minga.RenderModel",
  "Minga.Diagnostics.Diagnostic",
  "Minga.Git.MergeConflict.Entry",
  "Minga.Language.Highlight.InjectionRange",
  "Minga.Design.Tokens",
  "Minga.Command.Parser",
  "Minga.Keymap.Bindings",
  "Minga.Keymap.SharedGroups",
  "Minga.Keymap.KeyParser",
  "Minga.Keymap.NormalPrefixes",
  "Minga.Keymap.Sigil",
  "MingaAgent.Session.Prefix",
  "MingaAgent.Session.PrefixStore",
  "MingaEditor.UI.Picker.Item",
  "MingaAgent.Session.Transcript"
]

pure_modules = Enum.flat_map(pure_prefixes, &[&1, &1 <> ".*"])

[
  # Reach cannot classify every call (including pure Erlang iodata BIFs). Keep
  # :unknown for those calls, but forbid our logging wrapper explicitly.
  effects: [
    allowed: Enum.map(pure_modules, &{&1, [:pure, :exception, :unknown]})
  ],
  calls: [forbidden: [{pure_modules, "Minga.Log.*"}]],
  # Architecture removed in #2223, #2235, #2236 (cell-grid TUI chrome, layout, tree and sidebar renderers, per-frontend command dispatch) and in the semantic-transcript refactor 0a484999d (agent chat prefetch) must not come back. Module globs match across dots, so `Commands.*.GUI` covers any command submodule.
  source: [
    forbidden_modules: [
      "MingaEditor.Shell.Traditional.Chrome.TUI",
      "MingaEditor.Layout.TUI",
      "MingaEditor.Commands.*.GUI",
      "MingaEditor.Commands.*.TUI",
      "MingaEditor.RenderPipeline.AgentChatPrefetch"
    ],
    forbidden_files: [
      "lib/**/tree_renderer.ex",
      "lib/**/sidebar_renderer.ex",
      "lib/**/agent_chat_prefetch.ex"
    ]
  ]
]
