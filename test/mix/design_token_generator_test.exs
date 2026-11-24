Code.require_file("mix/design_token_generator.ex")

defmodule Minga.Mix.DesignTokenGeneratorTest do
  use ExUnit.Case, async: true

  alias Minga.Design.Tokens
  alias Minga.Mix.DesignTokenGenerator

  setup_all do
    {:ok, raw} = DesignTokenGenerator.source_path() |> File.read!() |> Toml.decode()
    %{raw: raw, tokens: DesignTokenGenerator.parse!(raw)}
  end

  test "checked-in Elixir, Swift and Go sources match the token file", %{tokens: tokens} do
    for {path, expected} <- DesignTokenGenerator.outputs(tokens) do
      assert File.read!(path) == expected, "#{path} is stale; run `mix codegen`"
    end
  end

  test "the compiled token module agrees with the token file", %{tokens: tokens} do
    assert Tokens.color_roles() == Enum.map(tokens.roles, &String.to_existing_atom(&1.id))
    assert Tokens.state_ids() == Enum.map(tokens.states, &String.to_existing_atom(&1.id))

    for state <- tokens.states do
      token = Tokens.state(String.to_existing_atom(state.id))
      assert token.word == state.word
      assert token.tui_glyph == state.tui_glyph
      assert token.role == String.to_existing_atom(state.role)
      assert token.shape == String.to_existing_atom(state.shape)
    end

    for {line, text} <- tokens.voice do
      assert Tokens.voice(String.to_existing_atom(line)) == text
    end
  end

  test "the six states use the words, shapes and roles of docs/design/marks.md" do
    assert for(id <- Tokens.state_ids(), do: {id, Tokens.state_word(id), Tokens.state_role(id)}) ==
             [
               {:working, "Working", :minga},
               {:needs_you, "Needs you", :needs_you},
               {:waiting, "Waiting", :waiting},
               {:stopped, "Stopped", :waiting},
               {:failed, "Failed", :failure},
               {:done, "Done", :done}
             ]

    assert Tokens.state(:waiting).shape == Tokens.state(:stopped).shape
    assert Tokens.voice(:welcome) == "Servus."
    assert Tokens.voice(:done) == "Passt."
    assert Tokens.voice(:farewell) == "Ciao."
  end

  test "every frontend output names each state's word and glyph", %{tokens: tokens} do
    outputs = Map.new(DesignTokenGenerator.outputs(tokens))

    for {path, source} <- outputs, state <- tokens.states do
      assert source =~ ~s("#{state.word}"), "#{path} is missing #{state.word}"
      assert source =~ ~s("#{state.tui_glyph}"), "#{path} is missing #{state.tui_glyph}"
    end
  end

  test "rejects a slot shared by two roles", %{raw: raw} do
    [first, second | rest] = raw["color_roles"]
    raw = %{raw | "color_roles" => [first, %{second | "slot" => first["slot"]} | rest]}

    assert_raise Mix.Error, ~r/slot 0x70 is shared/, fn -> DesignTokenGenerator.parse!(raw) end
  end

  test "rejects a slot outside the role range", %{raw: raw} do
    [first | rest] = raw["color_roles"]
    raw = %{raw | "color_roles" => [%{first | "slot" => 0x5C} | rest]}

    assert_raise Mix.Error, ~r/slot must be in 0x70..0x8F/, fn ->
      DesignTokenGenerator.parse!(raw)
    end
  end

  test "rejects a state that names an unknown role", %{raw: raw} do
    [first | rest] = raw["states"]
    raw = %{raw | "states" => [%{first | "role" => "purple"} | rest]}

    assert_raise Mix.Error, ~r/unknown colour role "purple"/, fn ->
      DesignTokenGenerator.parse!(raw)
    end
  end

  test "rejects an unknown state shape", %{raw: raw} do
    [first | rest] = raw["states"]
    raw = %{raw | "states" => [%{first | "shape" => "star"} | rest]}

    assert_raise Mix.Error, ~r/shape must be one of/, fn -> DesignTokenGenerator.parse!(raw) end
  end

  test "rejects a role with neither a source nor a mix", %{raw: raw} do
    [first | rest] = raw["color_roles"]
    raw = %{raw | "color_roles" => [Map.delete(first, "source") | rest]}

    assert_raise Mix.Error, ~r/needs a source/, fn -> DesignTokenGenerator.parse!(raw) end
  end

  test "rejects a fourth voice line", %{raw: raw} do
    raw = put_in(raw, ["voice", "greeting"], "Grüß Gott.")

    assert_raise Mix.Error, ~r/must define exactly welcome, done, farewell/, fn ->
      DesignTokenGenerator.parse!(raw)
    end
  end
end
