defmodule Minga.Agent.View.Help do
  @moduledoc """
  Keybinding reference for the agentic view help overlay.

  Provides structured binding descriptions grouped by category for
  the chat navigation and file viewer contexts. Used by the renderer
  to draw the `?` help popup.
  """

  @typedoc "A single binding entry."
  @type binding :: {String.t(), String.t()}

  @typedoc "A group of bindings with a category label."
  @type group :: {String.t(), [binding()]}

  @doc "Returns keybinding groups for chat navigation mode."
  @spec chat_bindings() :: [group()]
  def chat_bindings do
    [
      {"Navigation",
       [
         {"j / k", "Scroll down / up"},
         {"Ctrl-d / Ctrl-u", "Half page down / up"},
         {"gg / G", "Scroll to top / bottom"},
         {"/ (search)", "Search messages (stubbed)"},
         {"n / N", "Next / prev search result (stubbed)"}
       ]},
      {"Fold / Collapse",
       [
         {"o / za", "Toggle collapse at cursor"},
         {"zA", "Toggle all collapses"},
         {"zM", "Collapse all"},
         {"zR", "Expand all"}
       ]},
      {"Jump",
       [
         {"]m / [m", "Next / prev message"},
         {"]c / [c", "Next / prev code block"},
         {"]t / [t", "Next / prev tool call"}
       ]},
      {"Copy",
       [
         {"y", "Copy code block at cursor"},
         {"Y", "Copy full message at cursor"}
       ]},
      {"Input",
       [
         {"i / a / Enter", "Focus chat input"},
         {"Shift+Enter", "Insert newline in input"},
         {"Up / Down", "History / cursor in input"}
       ]},
      {"Session",
       [
         {"Ctrl-c", "Abort agent"},
         {"Ctrl-l", "Clear display"},
         {"SPC a n", "New session"},
         {"SPC a s", "Stop agent"},
         {"SPC a m", "Pick model"},
         {"SPC a T", "Cycle thinking level"}
       ]},
      {"Panel",
       [
         {"Tab", "Switch focus (chat / viewer)"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q", "Close agentic view"},
         {"?", "This help overlay"}
       ]}
    ]
  end

  @doc "Returns keybinding groups for file viewer mode."
  @spec viewer_bindings() :: [group()]
  def viewer_bindings do
    [
      {"Navigation",
       [
         {"j / k", "Scroll down / up"},
         {"Ctrl-d / Ctrl-u", "Half page down / up"},
         {"gg / G", "Scroll to top / bottom"}
       ]},
      {"Session",
       [
         {"Ctrl-c", "Abort agent"}
       ]},
      {"Panel",
       [
         {"Tab / Escape", "Switch focus to chat"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q", "Close agentic view"},
         {"?", "This help overlay"}
       ]}
    ]
  end
end
