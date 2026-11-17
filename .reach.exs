# Reach architecture policy (`mix reach.check --arch`, about 12s).
#
# Layer direction stays in `Minga.Credo.DependencyDirectionCheck` (EX9001); it owns global Layer 0/1/2 and Agent-internal level classification. This file holds runtime effect contracts for pure foundations and explicit pure Agent values, plus deleted architecture that must not return.
#
# Known Reach 2.8.4 hazard (https://github.com/elixir-vibe/reach/issues/46): plugin detection scans `lib/**` source for the substrings "Ecto" and "Phoenix.*" and, when found anywhere including a docstring, activates plugins that classify every local call named `add`, `remove`, `delete`, `get`, `put`, `create`, `drop`, `rename`, or `update` as a write. If this gate suddenly reports writes in pure code, `mix run --no-start -e 'IO.inspect(Reach.Plugin.Inference.infer(["lib"]))'` should print `[]`; if it does not, find the new mention and reword it.
# Agent-internal Level 0 is not global Layer 0: these values may depend on other
# pure Agent contracts without promoting the whole Agent namespace globally.
agent_pure_effects = [
  {"MingaAgent.Session.Transcript", [:pure, :exception, :unknown, :io]},
  {"MingaAgent.Session.Transcript.*", [:pure, :exception, :unknown, :io]}
]

[
  # Global pure foundations mirror `@layer_0_prefixes` in Credo, each with a child twin. Explicit Agent-internal pure effects are appended separately; reach_policy_test guards the exact combined policy and keeps the two classifications disjoint. `:io` permits pure IO.iodata_* helpers, not stateful effects; EX9003 blocks direct Logger use.
  effects: [
    allowed:
      [
        {"Minga.Buffer.ChangeLog", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.ChangeLog.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.ConflictIndex", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.ConflictIndex.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Cursor", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Cursor.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Document", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Document.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.EditDelta", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.EditDelta.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.EditSource", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.EditSource.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.FileMutation", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.FileMutation.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Lines", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Lines.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Position", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Position.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.RenderSnapshot", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.RenderSnapshot.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.SaveState", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.SaveState.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Selection", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Selection.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Span", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.Span.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.State", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.State.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.UndoHistory", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.UndoHistory.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.UndoPatch", [:pure, :exception, :unknown, :io]},
        {"Minga.Buffer.UndoPatch.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Motion", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Motion.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Operator", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Operator.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.TextObject", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.TextObject.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Search", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Search.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.AutoPair", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.AutoPair.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Comment", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Comment.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Text.Readable", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Text.Readable.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.NavigableContent", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.NavigableContent.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Scroll", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Scroll.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Fold.Range", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Fold.Range.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Model", [:pure, :exception, :unknown, :io]},
        {"Minga.Editing.Model.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Core", [:pure, :exception, :unknown, :io]},
        {"Minga.Core.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Mode", [:pure, :exception, :unknown, :io]},
        {"Minga.Mode.*", [:pure, :exception, :unknown, :io]},
        {"Minga.RenderModel", [:pure, :exception, :unknown, :io]},
        {"Minga.RenderModel.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Diagnostics.Diagnostic", [:pure, :exception, :unknown, :io]},
        {"Minga.Diagnostics.Diagnostic.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Git.MergeConflict.Entry", [:pure, :exception, :unknown, :io]},
        {"Minga.Git.MergeConflict.Entry.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Language.Highlight.InjectionRange", [:pure, :exception, :unknown, :io]},
        {"Minga.Language.Highlight.InjectionRange.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Command.Parser", [:pure, :exception, :unknown, :io]},
        {"Minga.Command.Parser.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.Bindings", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.Bindings.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.SharedGroups", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.SharedGroups.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.KeyParser", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.KeyParser.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.NormalPrefixes", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.NormalPrefixes.*", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.Sigil", [:pure, :exception, :unknown, :io]},
        {"Minga.Keymap.Sigil.*", [:pure, :exception, :unknown, :io]},
        {"MingaAgent.Session.Prefix", [:pure, :exception, :unknown, :io]},
        {"MingaAgent.Session.Prefix.*", [:pure, :exception, :unknown, :io]},
        {"MingaAgent.Session.PrefixStore", [:pure, :exception, :unknown, :io]},
        {"MingaAgent.Session.PrefixStore.*", [:pure, :exception, :unknown, :io]},
        {"MingaEditor.UI.Picker.Item", [:pure, :exception, :unknown, :io]},
        {"MingaEditor.UI.Picker.Item.*", [:pure, :exception, :unknown, :io]}
      ] ++ agent_pure_effects
  ],
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
