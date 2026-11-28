defmodule Minga.Test.Storyboard.Scenarios.Code do
  @moduledoc "Registry entries for the `code` journey: diagnostics, hover, code actions and references."

  import ExUnit.Assertions
  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @hover_doc """
  ```elixir
  greet(name :: String.t()) :: String.t()
  ```

  Returns a greeting for the given name.

  The name is preserved exactly, including whitespace and punctuation. The return value is a string, not terminal output.

  ## Examples

  ```elixir
  greet("Maya")
  #=> "Hello, Maya"
  ```

  A caller can use the same function for dialog labels, notifications and logs. It does not read the active project or modify the editor.

  See the [String reference](https://hexdocs.pm/elixir/String.html) for character and encoding examples.
  """

  @diagnostic "Unused argument name"

  @doc "Every `code` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "code.diagnostics.in_file",
        4059,
        "diagnostics share one gutter and one grammar"
      ),
      Entry.built("code.hover",
        start: [content: "greet(name)\n", hover_source: [markdown: @hover_doc]],
        reach: "K",
        recognize: fn model ->
          Enum.any?(hover_lines(model, false), &String.contains?(&1, "Returns a greeting")) and
            not diagnostic_hover?(model)
        end,
        checks: [
          Check.new(
            "the compact hover previews the signature and one paragraph",
            &compact_hover/1
          )
        ]
      ),
      Entry.built("code.diagnostics.hover",
        start: [
          content: "greet(name)\n",
          hover_source: [diagnostic: @diagnostic, markdown: @hover_doc]
        ],
        reach: "K",
        recognize: &diagnostic_hover?/1,
        checks: [
          Check.new(
            "the diagnostic precedes signature and docs, with one Act menu",
            &diagnostic_hover/1
          )
        ]
      ),
      Entry.built("code.diagnostics.none",
        reach: "1 SPC c x",
        recognize: &Model.empty_picker?(&1, ~r/diagnostics/i, ~r/^No problem/),
        checks: [
          Check.new("an empty list says so and points somewhere", fn model ->
            assert_empty_state(model,
              title: "No problems in this file.",
              description: "No language server checks this file.",
              actions: [
                {"SPC c l I", "Install a language server"},
                {"SPC c l i", "Show what ran"}
              ]
            )
          end)
        ]
      ),
      Entry.built("code.actions.none",
        reach: "1 SPC c a",
        recognize: &(is_binary(&1.echo) and &1.echo =~ ~r/^No code actions/),
        checks: [
          Check.new(
            "the echo line answers and names the next step, and nothing opens",
            fn model ->
              model
              |> assert_notice("No code actions at 1:1 (no language server)", [
                {"SPC a ?", "ask Minga"}
              ])
              |> assert_resting()
            end
          )
        ]
      ),
      Entry.built("code.references.none",
        reach: "1 SPC c D",
        recognize: &(is_binary(&1.echo) and &1.echo =~ ~r/^No references/),
        checks: [
          Check.new(
            "the echo line answers and names the next step, and nothing opens",
            fn model ->
              model
              |> assert_notice("No references to defmodule (no server)", [
                {"SPC s p", "search the project"}
              ])
              |> assert_resting()
            end
          )
        ]
      ),
      Entry.built("code.hover.focused",
        start: [content: "greet(name)\n", hover_source: [markdown: @hover_doc]],
        reach: "K K",
        recognize: &focused_hover?/1,
        checks: [
          Check.new(
            "the focused hover opens on the signature and retains the action hint",
            &focused_hover/1
          )
        ]
      )
    ]
  end

  @spec compact_hover(Model.t()) :: Model.t()
  defp compact_hover(model) do
    assert [heading, signature, _fence, "", "Returns a greeting for the given name."] =
             hover_lines(model, false)

    assert heading =~ "elixir"
    assert signature =~ "greet(name :: String.t())"
    assert %{actions?: true, open_label: nil} = model.ui.hover_popup
    model
  end

  @spec diagnostic_hover?(Model.t()) :: boolean()
  defp diagnostic_hover?(model) do
    case hover_lines(model, false) do
      [first | rest] ->
        first =~ @diagnostic and Enum.any?(rest, &String.contains?(&1, "Returns a greeting"))

      [] ->
        false
    end
  end

  @spec diagnostic_hover(Model.t()) :: Model.t()
  defp diagnostic_hover(model) do
    assert [diagnostic, "", _language, signature, _fence, "", docs] = hover_lines(model, false)
    assert diagnostic =~ @diagnostic
    assert signature =~ "greet(name :: String.t())"
    assert docs =~ "Returns a greeting"
    assert %{actions?: true, open_label: nil} = model.ui.hover_popup
    model
  end

  @spec focused_hover?(Model.t()) :: boolean()
  defp focused_hover?(model) do
    Enum.any?(hover_lines(model, true), &String.contains?(&1, "greet(name :: String.t())"))
  end

  @spec focused_hover(Model.t()) :: Model.t()
  defp focused_hover(model) do
    assert focused_hover?(model)
    assert %{actions?: true, open_label: nil} = model.ui.hover_popup
    model
  end

  @spec hover_lines(Model.t(), boolean()) :: [String.t()]
  defp hover_lines(
         %Model{ui: %{hover_popup: %{visible?: true, focused?: focused, content_lines: lines}}},
         focused
       ) do
    Enum.map(lines, fn line -> Enum.map_join(line.segments, & &1.text) end)
  end

  defp hover_lines(%Model{}, _focused), do: []
end
