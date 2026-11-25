defmodule Minga.Test.Storyboard.Scenarios.Edit do
  @moduledoc """
  Registry entries for the `edit` journey: plain editing, the leader which-key and visual selection.

  `edit.plain` is the factory's cold start and its home: every way-out check ends here.
  """

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `edit` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("edit.plain",
        reach: "",
        recognize: &home?/1,
        click_reach: [],
        explore: :normal,
        checks: [
          Check.new("a resting view: nothing transient, nothing pending", &assert_resting/1),
          Check.new("the editor owns the keyboard", &assert_focus(&1, :editor)),
          Check.new("the mode pill says NORMAL", &assert_mode(&1, :normal)),
          Check.new(
            "modeline segments in design order: mode, file, filetype, position",
            &assert_modeline_order(&1, [:mode, :file, :filetype, :position])
          ),
          Check.new(
            "a narrow window drops filetype, then position; mode and file never drop",
            &assert_drop_order(&1, [:filetype, :position], [:mode, :file])
          )
        ]
      ),
      Entry.built("edit.whichkey.leader",
        reach: "SPC (pause)",
        recognize: &which_key?(&1, "SPC"),
        explore: :which_key,
        checks: [
          Check.new("which-key is open on SPC", &assert_which_key(&1, "SPC")),
          Check.new(
            "the editor keeps the keyboard while which-key is open",
            &assert_focus(&1, :editor)
          ),
          Check.new(
            "the exits a, f and SPC are shown",
            &assert_keys_shown(&1, ["a", "f", "SPC"])
          ),
          Check.new("SPC , switches files", &assert_keys_shown(&1, [","])),
          Check.new(
            "groups read like leaves: Title Case, no +",
            &assert_groups_read_like_leaves/1
          ),
          Check.new("the Minga group reads Minga ›", &assert_group(&1, "a", "Minga")),
          Check.new(
            "entries read in the designed sections",
            &assert_sections(&1, ["Groups", "Often", "More"])
          )
        ]
      ),
      Entry.built("edit.visual",
        reach: "v",
        recognize:
          &(&1.mode in [:visual, :visual_line, :visual_block] and not Model.transient_open?(&1)),
        checks: [
          Check.new("the mode pill says VISUAL", &assert_mode(&1, :visual)),
          Check.new("the editor owns the keyboard", &assert_focus(&1, :editor)),
          Check.new(
            "modeline segments in design order, position as line:col",
            &(&1
              |> assert_modeline_order([:mode, :file, :filetype, :position])
              |> assert_position_line_col())
          )
        ]
      ),
      Entry.pending(
        "edit.working",
        4050,
        "Minga's changes in the gutter while it works in the file"
      ),
      Entry.pending("chrome.tooltip", 4053, "hover teaches a modeline segment's meaning and key"),
      Entry.built("edit.command_line",
        reach: ":",
        recognize: &(&1.mode == :command and not Model.open?(&1, :which_key))
      )
    ]
  end

  @doc "True for the resting home view: Normal mode, nothing transient, nothing pending, the editor focused, and no notice naming next steps."
  @spec home?(Model.t()) :: boolean()
  def home?(%Model{} = model) do
    model.mode == :normal and not Model.transient_open?(model) and not Model.key_pending?(model) and
      match?(%{surface: :editor}, model.focus) and not Model.notice_with_next_steps?(model)
  end

  @doc "True when which-key is open on exactly `prefix`."
  @spec which_key?(Model.t(), String.t()) :: boolean()
  def which_key?(%Model{which_key: %{prefix: prefix}}, prefix), do: true
  def which_key?(%Model{}, _prefix), do: false
end
