# Reach architecture policy (`mix reach.check --arch`, about 12s).
#
# Layer direction stays in `Minga.Credo.DependencyDirectionCheck` (EX9001); it owns the Layer 0/1/2 module classification and the allowed-reference list, and a second copy here would drift. This file holds what that check cannot express.
#
# Not yet enabled: `effects: [allowed: ...]` for the `@layer_0_prefixes` pure modules. Measured against the tree it reports 24 findings: 16 real filesystem calls in `Minga.Core.Overlay` (misfiled in Layer 0), 2 `System.monotonic_time` reads in `Minga.Buffer.UndoHistory`, and 6 classifier false positives on pure code (`ContentDigest.add`, `IntervalTree.delete`, `Selection.clear_line`). Enable it once Overlay moves out of Layer 0 and the remaining findings are baselined.
[
  # Architecture removed in #2223, #2235, #2236 (cell-grid TUI chrome, layout, tree and sidebar renderers, per-frontend command dispatch) and #2680 (agent chat prefetch) must not come back. Module globs match across dots, so `Commands.*.GUI` covers any command submodule.
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
