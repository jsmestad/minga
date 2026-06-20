defmodule MingaEditor.Commands.AutobiographyCommandTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias MingaAgent.Autobiography.Entry
  alias MingaEditor.Commands.Autobiography

  defp entry(opts \\ []) do
    %Entry{
      path: Keyword.get(opts, :path, "/proj/lib/router.ex"),
      session_id: Keyword.get(opts, :session_id, "a1b2c3d4e5f6"),
      tool_call_id: "tc1",
      tool_name: "apply_diff",
      occurred_at: Keyword.get(opts, :occurred_at, ~U[2026-03-08 14:22:00Z]),
      user_request: Keyword.get(opts, :user_request, "add auth handling"),
      thinking: Keyword.get(opts, :thinking, "use middleware"),
      assistant_text: Keyword.get(opts, :assistant_text, "Added an auth middleware.")
    }
  end

  test "provider exports the code-provenance commands" do
    names = Autobiography.__commands__() |> Enum.map(& &1.name)
    assert :code_why in names
    assert :code_autobiography in names
  end

  test "both commands require an active buffer" do
    for cmd <- Autobiography.__commands__() do
      assert cmd.requires_buffer
    end
  end

  test "SPC g w resolves to :code_why and SPC g a to :code_autobiography" do
    trie = Defaults.leader_trie()
    {:prefix, g_node} = Bindings.lookup(trie, {?g, 0})
    assert {:command, :code_why} = Bindings.lookup(g_node, {?w, 0})
    assert {:command, :code_autobiography} = Bindings.lookup(g_node, {?a, 0})
  end

  describe "why_markdown/2" do
    test "renders request, thinking, agent text, and the open-session hint" do
      md = Autobiography.why_markdown(entry(), "/proj/lib/router.ex")

      assert md =~ "Why is this line like this?"
      assert md =~ "router.ex"
      assert md =~ "session a1b2c3d4"
      assert md =~ "Mar 8, 2026"
      assert md =~ "add auth handling"
      assert md =~ "use middleware"
      assert md =~ "Added an auth middleware."
      assert md =~ "_Enter: open this session_"
    end

    test "omits the request line when there is no recorded request" do
      md = Autobiography.why_markdown(entry(user_request: nil), "/p/a.ex")
      refute md =~ "You asked"
    end

    test "truncates very long thinking" do
      md = Autobiography.why_markdown(entry(thinking: String.duplicate("x", 1000)), "/p/a.ex")
      assert md =~ "…"
    end
  end

  describe "autobiography_markdown/2" do
    test "renders a header with the turn count and each entry" do
      entries = [entry(session_id: "newsessionid"), entry(session_id: "oldsessionid")]
      md = Autobiography.autobiography_markdown(entries, "/proj/lib/router.ex")

      assert md =~ "Autobiography — `router.ex`"
      assert md =~ "2 agent edit-turn(s)"
      assert md =~ "session newsessi"
      assert md =~ "session oldsessi"
    end

    test "caps the list and notes the overflow" do
      entries = for n <- 1..16, do: entry(session_id: "s#{n}")
      md = Autobiography.autobiography_markdown(entries, "/p/a.ex")

      assert md =~ "16 agent edit-turn(s)"
      assert md =~ "showing 15 most recent"
    end
  end
end
