defmodule MingaEditor.Commands.HealthTest do
  @moduledoc "`:checkhealth` and its terminal page, as typed on the command line."
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Command.Parser
  alias Minga.Config.Options
  alias MingaEditor.Commands.Health
  alias MingaEditor.Frontend.TerminalReport
  alias MingaEditor.State.Frontend

  describe "the command line" do
    test "parses the command with and without a page name" do
      assert Parser.parse("checkhealth") == {:checkhealth, []}
      assert Parser.parse("checkhealth terminal") == {:checkhealth, ["terminal"]}
      assert Parser.parse("checkhealth  terminal ") == {:checkhealth, ["terminal"]}
      assert Parser.parse("checkhealth lsp") == {:checkhealth, ["lsp"]}
      assert Parser.parse("checkhealth  ") == {:checkhealth, []}
    end
  end

  describe ":checkhealth terminal" do
    test "in a terminal lists each feature with what the frontend reported" do
      ctx = start_editor("hello", backend: :tui)

      report =
        TerminalReport.new([
          {:true_color, :detected, :answered},
          {:styled_underlines, :fallback, :timeout}
        ])

      send(ctx.editor, {:minga_input, {:terminal_report, report}})
      send_ex_sync(ctx, "checkhealth terminal")

      page = active_content(ctx)
      assert page =~ ~r/24-bit colour\s+detected\s+the terminal answered/
      assert page =~ ~r/Curly and dotted underlines\s+fallback\s+the terminal did not answer/
      assert page =~ "Minga uses a plain underline."
      assert page =~ ~r/Clickable file:line\s+not used yet/
    end

    test "says when the option forces a feature the running frontend was not started with" do
      options = start_supervised!({Options, name: nil})
      assert {:ok, _value} = Options.set(options, :terminal_features, %{styled_underlines: :on})
      ctx = start_editor("hello", backend: :tui, options_server: options)

      send(
        ctx.editor,
        {:minga_input,
         {:terminal_report, TerminalReport.new([{:styled_underlines, :fallback, :timeout}])}}
      )

      send_ex_sync(ctx, "checkhealth terminal")

      page = active_content(ctx)
      assert page =~ "Set in your config, not applied: styled_underlines on."
      assert page =~ "Restart Minga to apply it."
    end

    test "in a terminal that has not reported yet says to ask again" do
      ctx = start_editor("hello", backend: :tui)
      send_ex_sync(ctx, "checkhealth terminal")

      assert active_content(ctx) =~ "has not reported yet"
    end

    test "outside a terminal says so in one sentence" do
      ctx = start_editor("hello")
      send_ex_sync(ctx, "checkhealth terminal")

      page = active_content(ctx)
      assert page =~ "This is not a terminal."
      refute page =~ "24-bit colour"
    end

    test "does not change the file the user was in" do
      ctx = start_editor("hello")
      original = ctx.buffer
      send_ex_sync(ctx, "checkhealth terminal")

      assert Minga.Buffer.content(original) == "hello"
    end
  end

  describe ":checkhealth without a page" do
    test "lists the pages that exist" do
      ctx = start_editor("hello")
      send_ex_sync(ctx, "checkhealth")

      page = active_content(ctx)
      assert page =~ "Health pages"
      assert page =~ ":checkhealth terminal"
    end

    test "with a name that has no page says so and lists the pages" do
      ctx = start_editor("hello")
      send_ex_sync(ctx, "checkhealth lsp")

      page = active_content(ctx)
      assert page =~ ~s(There is no health page named "lsp".)
      assert page =~ ":checkhealth terminal"
    end
  end

  describe "subject/1" do
    test "is the report when there is one, whatever the backend" do
      report = TerminalReport.new(true_color: :detected)
      frontend = Frontend.accept_terminal_report(Frontend.new(backend: :tui), report)

      assert Health.subject(frontend) == report
    end

    test "tells a terminal without a report from a frontend that is not a terminal" do
      assert Health.subject(Frontend.new(backend: :tui)) == :no_report

      for backend <- [:gui, :native_gui, :headless] do
        assert Health.subject(Frontend.new(backend: backend)) == :not_a_terminal
      end
    end
  end
end
