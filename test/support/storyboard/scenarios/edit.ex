defmodule Minga.Test.Storyboard.Scenarios.Edit do
  @moduledoc """
  Registry entries for the `edit` journey: plain editing, the leader which-key and visual selection.

  The factory's cold start is the project home (`start.open_dir.home`); `1` opens the project's file there, which is `edit.plain`.
  """

  import ExUnit.Assertions, only: [assert: 1, refute: 1]
  import Minga.Test.Storyboard.Assertions

  alias Minga.Buffer.EditSource
  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @working_content """
  defmodule Limits do
    def allowed?(count) do
      count < 60
    end
  end
  """

  @doc "Every `edit` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("edit.plain",
        reach: "1",
        recognize: &plain?/1,
        click_reach: [{:gui_action, {:empty_state_activate, "recent-1"}}],
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
        reach: "1 SPC (pause)",
        # The mode pill is the mouse's front door.
        click_reach: [
          {:gui_action, {:empty_state_activate, "recent-1"}},
          {:gui_action, {:execute_command, "which_key_open"}}
        ],
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
        reach: "1 v",
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
      Entry.built("edit.working",
        start: [
          minga: {:thinking, :in_file},
          tasks: [{"Add tests for the usage-limit classifier", :needs_you}],
          content: @working_content,
          review_task: [id: "limits", title: "Update the usage limit"],
          review_edits: [
            {{2, 4}, 10, "count >= 0 and\n      count < 90", EditSource.minga("limits", "guard")},
            {{1, 6}, 8, "within_limit?", :user}
          ]
        ],
        reach: "g g",
        recognize: &working?/1,
        checks: [
          Check.new(
            "the editor keeps the keyboard while Minga works",
            &assert_focus(&1, :editor)
          ),
          Check.new("Minga is working in this file", fn model ->
            assert Enum.any?(Model.modeline_segments(model), fn segment ->
                     segment.id == :minga and segment.text == "Minga here"
                   end)

            model
          end),
          Check.new("review position is absent outside a pending change", fn model ->
            refute Enum.any?(Model.modeline_segments(model), &(&1.id == :change))
            model
          end)
        ]
      ),
      Entry.pending("chrome.tooltip", 4053, "hover teaches a modeline segment's meaning and key"),
      Entry.built("edit.command_line",
        reach: "1 :",
        recognize: &(&1.mode == :command and not Model.open?(&1, :which_key))
      )
    ]
  end

  @spec plain?(Model.t()) :: boolean()
  defp plain?(%Model{} = model) do
    home?(model) and
      not Enum.any?(Model.modeline_segments(model), fn
        %{id: :minga, state: :working} -> true
        %{id: :change} -> true
        _other -> false
      end)
  end

  @spec working?(Model.t()) :: boolean()
  defp working?(%Model{} = model) do
    segments = Model.modeline_segments(model)

    home?(model) and
      Enum.any?(segments, &match?(%{id: :minga, state: :working}, &1)) and
      not Enum.any?(segments, &(&1.id == :change))
  end

  @doc "True for the resting home view: Normal mode, nothing transient, nothing pending, the editor focused, and no notice naming next steps."
  @spec home?(Model.t()) :: boolean()
  def home?(%Model{} = model) do
    model.review_text == nil and model.mode == :normal and not Model.transient_open?(model) and
      not Model.key_pending?(model) and match?(%{surface: :editor}, model.focus) and
      not Model.notice_with_next_steps?(model)
  end

  @doc "True when which-key is open on exactly `prefix`."
  @spec which_key?(Model.t(), String.t()) :: boolean()
  def which_key?(%Model{which_key: %{prefix: prefix}}, prefix), do: true
  def which_key?(%Model{}, _prefix), do: false
end
