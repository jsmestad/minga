for path <- Path.wildcard("credo/checks/*.exs"), do: Code.require_file(path)

defmodule Minga.Docs.AgentsMdTest do
  @moduledoc "Checks that the agent guides point at repository paths and loadable layer entry points."

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @guides ["AGENTS.md", "macos/AGENTS.md"]
  @repo_prefix ~r/^(lib|test|docs|macos|go|zig|scripts|credo|config|mix|extensions)\//
  @module_name ~r/^Minga(?:Editor|Agent)?(?:\.[A-Z][A-Za-z0-9]*)*$/

  for guide <- @guides do
    @guide guide

    test "#{guide} names existing repository paths" do
      missing =
        @root
        |> Path.join(@guide)
        |> File.read!()
        |> backticked_tokens()
        |> Enum.filter(&Regex.match?(@repo_prefix, &1))
        |> Enum.map(&normalize_path/1)
        |> Enum.uniq()
        |> Enum.reject(&path_exists?/1)

      assert missing == [], "#{@guide} names missing paths:\n#{Enum.join(missing, "\n")}"
    end
  end

  test "the layer tables name loadable entry-point modules" do
    missing =
      @root
      |> Path.join("AGENTS.md")
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "|"))
      |> Enum.flat_map(fn row ->
        row |> String.split("|") |> Enum.at(2, "") |> backticked_tokens()
      end)
      |> Enum.filter(&Regex.match?(@module_name, &1))
      |> Enum.reject(&module_exists?/1)

    assert missing == [], "AGENTS.md names missing entry points: #{Enum.join(missing, ", ")}"
  end

  test "the guide lists every registered custom check with a unique ID" do
    {config, _bindings} = Code.eval_file(Path.join(@root, ".credo.exs"))

    registered =
      config.configs
      |> hd()
      |> get_in([:checks, :enabled])
      |> Enum.filter(fn {check, params} ->
        params != false and String.starts_with?(Atom.to_string(check), "Elixir.Minga.Credo.")
      end)
      |> Enum.map(fn {check, _params} -> {List.last(Module.split(check)), check.id()} end)

    documented =
      ~r/^\| `([A-Za-z]+Check)` \| (EX\d+) \|/m
      |> Regex.scan(File.read!(Path.join(@root, "AGENTS.md")), capture: :all_but_first)
      |> Enum.map(&List.to_tuple/1)

    assert Enum.sort(documented) == Enum.sort(registered)
    ids = Enum.map(registered, &elem(&1, 1))
    assert Enum.uniq(ids) == ids, "Custom Credo check IDs must not collide"
  end

  defp backticked_tokens(text) do
    ~r/(?<!`)`([^`\n]+)`(?!`)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp normalize_path(token) do
    token
    |> String.split(~r/\s+#|#(?=[a-zA-Z])/, parts: 2)
    |> hd()
    |> String.split()
    |> hd()
    |> String.replace(~r/:\d+(?:-\d+)?$/, "")
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp path_exists?(path) do
    absolute = Path.join(@root, path)

    if String.contains?(path, "*") do
      Path.wildcard(absolute) != []
    else
      File.exists?(absolute)
    end
  end

  defp module_exists?(name) do
    name
    |> then(&String.to_existing_atom("Elixir." <> &1))
    |> Code.ensure_loaded?()
  rescue
    ArgumentError -> false
  end
end
