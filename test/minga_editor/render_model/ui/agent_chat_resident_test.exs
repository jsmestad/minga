defmodule MingaEditor.RenderModel.UI.AgentChatResidentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.RenderModel.UI.AgentChat
  alias MingaAgent.ToolCall
  alias MingaEditor.RenderModel.UI.AgentChatResident

  defp identity, do: :presentation_identity

  describe "admission continuity" do
    test "a revision gap keeps the last good root; a foreign or baseless update installs none" do
      root = seed(rows(1..5), max_bytes: 10_000)

      for update <- [
            {:changes, identity(), 2, 3, 0, [{:put, {3, 9}, row(9)}]},
            {:unchanged, identity(), 7, 0}
          ] do
        assert {:reseed, ^root} = AgentChatResident.admit(root, update, context())
      end

      for update <- [
            {:changes, make_ref(), 1, 2, 0, [{:put, {3, 9}, row(9)}]},
            {:unchanged, make_ref(), 1, 0}
          ] do
        assert {:reseed, nil} = AgentChatResident.admit(root, update, context())
      end

      assert {:reseed, nil} =
               AgentChatResident.admit(nil, {:unchanged, identity(), 1, 0}, context())
    end

    test "a seed replaces any base and a contiguous update advances its revision" do
      root = seed(rows(1..3))
      update = {:changes, identity(), 1, 2, 5, [{:put, {3, 4}, row(4)}]}
      assert {:ok, next} = AgentChatResident.admit(root, update, context())
      assert {next.revision, next.epoch} == {2, 5}
      assert ids(next) == [1, 2, 3, 4]

      replacement = make_ref()
      seed = {:seed, replacement, 9, 1, keyed(rows(7..8))}

      assert {:ok, %{identity: ^replacement, revision: 9} = reseeded} =
               AgentChatResident.admit(next, seed, context())

      assert ids(reseeded) == [7, 8]
    end
  end

  describe "byte-capped newest suffix" do
    test "matches the list rule across tail growth, shrink, eviction, readmission and footer changes" do
      footer = [{900, {:system, "footer", :info}}]
      sizes = fn message -> 8 + :erlang.external_size(message) end
      base = rows(1..12)
      cap = Enum.sum(Enum.map(Enum.take(materialized(base), -4), sizes)) + 1
      root = seed(base, max_bytes: cap, footer: footer)
      assert_suffix(root, base, footer, cap)

      steps = [
        {[{:put, {3, 12}, row(12, String.duplicate("long ", 40))}], footer},
        {[{:put, {3, 12}, row(12, "short")}], footer},
        {[{:put, {3, 13}, row(13)}], []},
        {[{:delete, {3, 13}}],
         [{900, {:system, "footer", :info}}, {901, {:system, "second footer", :info}}]},
        {[{:put, {0, 0}, row(0)}, {:put, {1, 0}, separator(1, "pinned")}], footer}
      ]

      Enum.reduce(Enum.with_index(steps, 2), {root, keyed(base)}, fn {{changes, footer}, revision},
                                                                     {root, display} ->
        update = {:changes, identity(), revision - 1, revision, 0, changes}

        {:ok, root} =
          AgentChatResident.admit(root, update, context(max_bytes: cap, footer: footer))

        display = apply_display(display, changes)
        assert_suffix(root, Enum.map(display, &elem(&1, 1)), footer, cap)
        {root, display}
      end)
    end

    property "any ordered change sequence keeps the list rule's resident suffix" do
      check all(
              cap <- integer(1..600),
              seed_keys <- map(list_of(display_key(), max_length: 12), &Enum.uniq/1),
              steps <- list_of(step(), max_length: 12),
              max_runs: 150
            ) do
        display = Enum.sort_by(Enum.map(seed_keys, &{&1, keyed_item(&1, "seed")}), &elem(&1, 0))

        {:ok, root} =
          AgentChatResident.admit(
            nil,
            {:seed, identity(), 1, 0, display},
            context(max_bytes: cap)
          )

        assert_suffix(root, Enum.map(display, &elem(&1, 1)), [], cap)

        Enum.reduce(Enum.with_index(steps, 2), {root, display}, fn {{changes, footer}, revision},
                                                                   {root, display} ->
          changes = Enum.uniq_by(changes, &change_key/1)
          update = {:changes, identity(), revision - 1, revision, 0, changes}
          ctx = context(max_bytes: cap, footer: footer)
          {:ok, root} = AgentChatResident.admit(root, update, ctx)
          display = apply_display(display, changes)
          assert_suffix(root, Enum.map(display, &elem(&1, 1)), footer, cap)
          {root, display}
        end)
      end
    end

    test "keeps the newest entry even when it alone exceeds the cap" do
      root = seed(rows(1..3), max_bytes: 1)
      assert {[{3, _}], true} = AgentChatResident.resident_messages(root)
    end
  end

  describe "work" do
    test "a one-entry change derives and sizes exactly that entry" do
      root = seed(rows(1..500), max_bytes: 4_096, footer: [{900, {:system, "footer", :info}}])
      counter = counter()

      update = {:changes, identity(), 1, 2, 0, [{:put, {3, 250}, row(250, "revised")}]}

      ctx =
        context(max_bytes: 4_096, footer: [{900, {:system, "footer", :info}}], counter: counter)

      assert {:ok, next} = AgentChatResident.admit(root, update, ctx)
      assert counts(counter) == %{derived: 1, sized: 1}

      composer_only = {:unchanged, identity(), 2, 0}
      assert {:ok, settled} = AgentChatResident.admit(next, composer_only, ctx)
      assert counts(counter) == %{derived: 1, sized: 1}
      assert settled.selection == next.selection
    end
  end

  describe "approval decoration" do
    test "decorates only the latest running occurrence of a reused tool-call ID" do
      running = tool(1, "reused", :running)
      completed = tool(2, "reused", :complete)
      latest = tool(3, "reused", :running)
      root = seed([running, completed, latest], approval: {"reused", :approval})

      assert [{1, {:tool_call, _}}, {2, {:tool_call, _}}, {3, {:approved, _}}] = messages(root)

      complete_latest = tool(3, "reused", :complete)
      update = {:changes, identity(), 1, 2, 0, [{:put, {3, 3}, complete_latest}]}

      {:ok, next} =
        AgentChatResident.admit(root, update, context(approval: {"reused", :approval}))

      # No fallback to the older running occurrence.
      assert [{1, {:tool_call, _}}, {2, {:tool_call, _}}, {3, {:tool_call, _}}] = messages(next)
      assert next.decorated == nil
    end

    test "a new or cleared approval re-derives only the affected row" do
      root = seed([row(1), tool(2, "target", :running), row(3)])
      counter = counter()
      ctx = context(approval: {"target", :approval}, counter: counter)
      {:ok, pending} = AgentChatResident.admit(root, {:unchanged, identity(), 1, 0}, ctx)
      assert [{1, _}, {2, {:approved, _}}, {3, _}] = messages(pending)
      assert counts(counter) == %{derived: 1, sized: 1}

      cleared = context(counter: counter)
      {:ok, resolved} = AgentChatResident.admit(pending, {:unchanged, identity(), 1, 0}, cleared)
      assert [{1, _}, {2, {:tool_call, _}}, {3, _}] = messages(resolved)
      assert counts(counter) == %{derived: 2, sized: 2}
    end
  end

  defp assert_suffix(root, display, footer, cap) do
    expected =
      AgentChat.resident_suffix(materialized(display) ++ footer, cap, &size/1)

    assert AgentChatResident.resident_messages(root) == expected
  end

  defp materialized(items), do: Enum.map(items, &derive_message(&1, nil))

  defp seed(items, opts \\ []) do
    {:ok, root} =
      AgentChatResident.admit(nil, {:seed, identity(), 1, 0, keyed(items)}, context(opts))

    root
  end

  defp keyed(items) do
    Enum.map(items, fn
      {id, {:system, _, _}, nil} = item when id >= 4_000_000_000 -> {{1, 0}, item}
      {id, _message, _style} = item -> {{3, id}, item}
    end)
  end

  defp apply_display(display, changes) do
    changes
    |> Enum.reduce(Map.new(display), fn
      {:put, key, item}, acc -> Map.put(acc, key, item)
      {:delete, key}, acc -> Map.delete(acc, key)
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp display_key do
    one_of([
      tuple({constant(0), integer(0..20)}),
      constant({1, 0}),
      constant({2, 0}),
      tuple({constant(3), integer(0..40)}),
      constant({4, 0})
    ])
  end

  defp step do
    tuple({
      list_of(
        one_of([
          bind(display_key(), fn key ->
            map(string(:alphanumeric, max_length: 80), &{:put, key, keyed_item(key, &1)})
          end),
          map(display_key(), &{:delete, &1})
        ]),
        min_length: 1,
        max_length: 4
      ),
      list_of(
        map(integer(0..3), &{900 + &1, {:system, "footer #{&1}", :info}}),
        max_length: 2
      )
      |> map(&Enum.uniq_by(&1, fn {id, _} -> id end))
    })
  end

  defp keyed_item({class, ordinal}, text),
    do: {class * 1_000 + ordinal + 1, {:user, "#{class}/#{ordinal} #{text}"}, nil}

  defp change_key({:put, key, _item}), do: key
  defp change_key({:delete, key}), do: key

  defp rows(range), do: Enum.map(range, &row/1)
  defp row(id, text \\ nil), do: {id, {:user, text || "message #{id}"}, nil}
  defp separator(id, text), do: {4_000_000_000 + id, {:system, text, :info}, nil}

  defp tool(id, tool_call_id, status) do
    call = ToolCall.new(tool_call_id, "shell", %{})
    call = if status == :complete, do: ToolCall.complete(call, "done"), else: call
    {id, {:tool_call, call}, nil}
  end

  defp ids(root), do: root |> messages() |> Enum.map(&elem(&1, 0))
  defp messages(root), do: root |> AgentChatResident.resident_messages() |> elem(0)

  defp context(opts \\ []) do
    counter = Keyword.get(opts, :counter)

    %{
      scope: nil,
      approval: Keyword.get(opts, :approval),
      footer: Keyword.get(opts, :footer, []),
      max_bytes: Keyword.get(opts, :max_bytes, 1_000_000),
      derive: fn item, approval ->
        bump(counter, :derived)
        derive_message(item, approval)
      end,
      measure: fn message ->
        bump(counter, :sized)
        {:ok, size(message)}
      end,
      tool_id: fn
        {_id, {:tool_call, %ToolCall{id: id}}, _style} -> id
        _item -> nil
      end,
      decoratable?: &match?({_id, {:tool_call, %ToolCall{status: :running}}, _style}, &1)
    }
  end

  defp derive_message({id, {:tool_call, call}, _style}, approval) when approval != nil,
    do: {id, {:approved, call}}

  defp derive_message({id, message, _style}, _approval), do: {id, message}

  defp size(message), do: 8 + :erlang.external_size(message)

  defp counter, do: :counters.new(2, [])

  defp bump(nil, _metric), do: :ok
  defp bump(counter, :derived), do: :counters.add(counter, 1, 1)
  defp bump(counter, :sized), do: :counters.add(counter, 2, 1)

  defp counts(counter),
    do: %{derived: :counters.get(counter, 1), sized: :counters.get(counter, 2)}
end
