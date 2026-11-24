defmodule Minga.Storyboard.AssertionsTest do
  @moduledoc """
  The storyboard assertion DSL over hand-built semantic models: each assertion passes on a frame that matches the design and fails, naming the difference, on one that does not.

  Most surfaces these assertions describe land in later tickets, so this file is what proves the assertions work before a scenario turns them on.
  """

  use ExUnit.Case, async: true

  import Minga.Test.Storyboard.Assertions

  alias Minga.Design.Tokens
  alias Minga.RenderModel.UI
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.FocusOwner
  alias Minga.RenderModel.UI.Notifications
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.WhichKey
  alias Minga.Test.Storyboard.Model
  alias MingaEditor.UI.Theme

  @moduletag :storyboard

  @theme Theme.get!(Theme.default())

  defp model(opts \\ []) do
    segments =
      Keyword.get(opts, :segments, [
        {:mode, " NORMAL "},
        {:filename, " a.ex "},
        {:filetype, " Elixir "}
      ])

    colored = for {name, text} <- segments, do: {name, text, 0, 0, [], nil}
    colored = colored ++ Keyword.get(opts, :colored, [])

    data = %StatusBar.Data{
      mode: Keyword.get(opts, :mode, :normal),
      modeline_segments: %{left: colored, right: []},
      pending_keys: Keyword.get(opts, :pending, "")
    }

    ui = %UI{
      status_bar: %StatusBar{content_kind: :buffer, data: data},
      which_key: Keyword.get(opts, :which_key),
      focus_owner: %FocusOwner{
        responder: :editor_view,
        surface: Keyword.get(opts, :focus, :editor),
        window_id: 1
      },
      empty_state: Keyword.get(opts, :empty_state),
      notifications: Keyword.get(opts, :notifications)
    }

    Model.from_ui(ui, @theme)
  end

  defp which_key(bindings),
    do: %WhichKey{
      visible: true,
      prefix: "SPC",
      bindings: Enum.map(bindings, &Map.put_new(&1, :icon, nil))
    }

  describe "modeline" do
    test "segments in design order pass, an extra segment fails" do
      assert_modeline_order(model(), [:mode, :file, :filetype])

      error =
        assert_raise ExUnit.AssertionError, fn ->
          model(segments: [{:mode, "N"}, {:filename, "a"}, {:indent, "2"}, {:filetype, "ex"}])
          |> assert_modeline_order([:mode, :file, :filetype])
        end

      assert error.message =~ ":indent"
    end

    test "an expectation that breaks the design order is rejected" do
      assert_raise ArgumentError, fn -> assert_modeline_order(model(), [:file, :mode]) end
    end

    test "state words come from the tokens and draw in the state's colour role" do
      working = Tokens.state_word(:working)
      fg = Theme.state_color(@theme, :working)
      ok = model(colored: [{:minga, " ◐ Minga #{working} ", fg, 0, [], nil}])
      assert_state(ok, :modeline, :working)

      wrong =
        model(
          colored: [
            {:minga, " Minga #{working} ", Theme.role_color(@theme, :failure), 0, [], nil}
          ]
        )

      assert_raise ExUnit.AssertionError, ~r/minga role/, fn ->
        assert_state(wrong, :modeline, :working)
      end

      assert_raise ArgumentError, fn -> assert_state(ok, :modeline, :busy) end
    end

    test "a segment's colour role is checked by token name" do
      fg = Theme.role_color(@theme, :needs_you)
      assert_role(model(colored: [{:needs_you, " 1 ", fg, 0, [], nil}]), :needs_you, :needs_you)
      assert_raise ArgumentError, fn -> assert_role(model(), :mode, :not_a_role) end
    end
  end

  describe "which-key" do
    test "groups read like leaves with a trailing chevron" do
      ok = model(which_key: which_key([%{key: "a", description: "Minga ›", kind: :group}]))

      ok
      |> assert_which_key("SPC")
      |> assert_group("a", "Minga")
      |> assert_groups_read_like_leaves()

      old = model(which_key: which_key([%{key: "a", description: "+ai", kind: :group}]))
      assert_raise ExUnit.AssertionError, fn -> assert_group(old, "a", "Minga") end
      assert_raise ExUnit.AssertionError, ~r/\+ai/, fn -> assert_groups_read_like_leaves(old) end
    end

    test "leaves, live counts and shown keys" do
      wk =
        which_key([
          %{key: "a", description: "Tasks · 1 needs you", kind: :command},
          %{key: "v", description: "Conversation", kind: :command}
        ])

      model(which_key: wk)
      |> assert_leaf("v", "Conversation")
      |> assert_count("a", "1 needs you")
      |> assert_keys_shown(["a", "v"])

      assert_raise ExUnit.AssertionError, ~r/"r"/, fn ->
        assert_keys_shown(model(which_key: wk), ["r"])
      end
    end
  end

  describe "surfaces and focus" do
    test "a resting view has nothing transient and nothing pending" do
      model() |> assert_resting() |> assert_focus(:editor, window: 1) |> assert_mode(:normal)
      assert_raise ExUnit.AssertionError, fn -> assert_resting(model(pending: "SPC")) end

      assert_raise ExUnit.AssertionError, fn ->
        assert_resting(model(which_key: which_key([])))
      end

      assert_raise ExUnit.AssertionError, fn -> assert_focus(model(), :picker) end
    end

    test "which surface is open" do
      open = model(which_key: which_key([]))
      open |> assert_surface(:which_key) |> refute_surface(:picker)
      assert_raise ExUnit.AssertionError, fn -> assert_surface(model(), :which_key) end
    end
  end

  describe "empty states and notices" do
    test "the anatomy needs a title, actions and the first action preselected" do
      items = [
        %EmptyState.Item{id: "new", kind: :action, label: "New task", jump_key: "n"},
        %EmptyState.Item{id: "help", kind: :action, label: "Help", jump_key: "?"}
      ]

      state = fn focused ->
        %EmptyState{
          visible?: true,
          focused_id: focused,
          sections: [%EmptyState.Section{id: :start, title: "No tasks yet", items: items}]
        }
      end

      assert_empty_state(model(empty_state: state.("new")),
        title: "No tasks yet",
        actions: [{"n", "New task"}, {"?", "Help"}]
      )

      assert_raise ExUnit.AssertionError, ~r/preselected/, fn ->
        assert_empty_state(model(empty_state: state.("help")), [])
      end

      assert_raise ExUnit.AssertionError, fn -> assert_empty_state(model(), []) end
    end

    test "an error notice must name a next step" do
      notice = fn actions ->
        %Notifications{
          items: [
            %{
              id: "1",
              level: :error,
              title: "elixir-ls failed",
              body: "",
              source: "lsp",
              actions: actions,
              dismissable: true,
              auto_dismiss_ms: nil,
              created_at: 0,
              updated_at: 0
            }
          ]
        }
      end

      assert_errors_name_next_step(
        model(notifications: notice.([%{id: "restart", label: "Restart"}]))
      )

      assert_raise ExUnit.AssertionError, ~r/elixir-ls failed/, fn ->
        assert_errors_name_next_step(model(notifications: notice.([])))
      end
    end
  end
end
