defmodule Minga.Editor.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.SignatureHelp
  alias Minga.Theme

  @theme Theme.get!(:doom_one)
  @viewport {24, 80}

  @sample_response %{
    "signatures" => [
      %{
        "label" => "foo(bar, baz, qux)",
        "documentation" => "Does something useful.",
        "parameters" => [
          %{"label" => "bar", "documentation" => "The first arg"},
          %{"label" => "baz", "documentation" => "The second arg"},
          %{"label" => "qux", "documentation" => ""}
        ]
      },
      %{
        "label" => "foo(only_one)",
        "parameters" => [
          %{"label" => "only_one"}
        ]
      }
    ],
    "activeSignature" => 0,
    "activeParameter" => 0
  }

  describe "from_response/3" do
    test "parses a valid response" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      assert %SignatureHelp{} = sh
      assert length(sh.signatures) == 2
      assert sh.active_signature == 0
      assert sh.active_parameter == 0
    end

    test "returns nil for empty signatures" do
      resp = %{"signatures" => [], "activeSignature" => 0, "activeParameter" => 0}
      assert SignatureHelp.from_response(resp, 10, 20) == nil
    end

    test "parses parameter labels" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      [sig | _] = sh.signatures
      assert length(sig.parameters) == 3
      assert hd(sig.parameters).label == "bar"
    end

    test "extracts signature documentation" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      [sig | _] = sh.signatures
      assert sig.documentation == "Does something useful."
    end

    test "extracts parameter documentation" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      [sig | _] = sh.signatures
      assert hd(sig.parameters).documentation == "The first arg"
    end

    test "handles label offset format [start, end]" do
      resp = %{
        "signatures" => [
          %{
            "label" => "func(a, b)",
            "parameters" => [%{"label" => [5, 6]}, %{"label" => [8, 9]}]
          }
        ],
        "activeSignature" => 0,
        "activeParameter" => 0
      }

      sh = SignatureHelp.from_response(resp, 10, 20)
      [sig | _] = sh.signatures
      # Label offsets are stored as "start:end" strings
      assert hd(sig.parameters).label == "5:6"
    end
  end

  describe "next_signature/1 and prev_signature/1" do
    test "cycles forward through signatures" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      assert sh.active_signature == 0
      sh = SignatureHelp.next_signature(sh)
      assert sh.active_signature == 1
      sh = SignatureHelp.next_signature(sh)
      assert sh.active_signature == 0
    end

    test "cycles backward through signatures" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      sh = SignatureHelp.prev_signature(sh)
      assert sh.active_signature == 1
      sh = SignatureHelp.prev_signature(sh)
      assert sh.active_signature == 0
    end
  end

  describe "render/3" do
    test "returns empty list for no signatures" do
      sh = %SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 10,
        anchor_col: 20
      }

      assert SignatureHelp.render(sh, @viewport, @theme) == []
    end

    test "produces draw commands for valid signature" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      draws = SignatureHelp.render(sh, @viewport, @theme)
      assert draws != []
      assert Enum.all?(draws, &is_tuple/1)
    end

    test "includes the signature label text" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      draws = SignatureHelp.render(sh, @viewport, @theme)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "foo")
      assert String.contains?(combined, "bar")
    end

    test "active parameter is rendered with highlighting" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      draws = SignatureHelp.render(sh, @viewport, @theme)

      # Find the draw that contains the active parameter "bar"
      bar_draws = Enum.filter(draws, fn {_r, _c, text, _s} -> text == "bar" end)
      assert bar_draws != []

      [{_r, _c, _text, %Minga.Face{} = face}] = bar_draws
      assert face.bold == true
    end

    test "shows signature counter when multiple overloads" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      draws = SignatureHelp.render(sh, @viewport, @theme)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "1/2")
    end

    test "positions above the cursor" do
      sh = SignatureHelp.from_response(@sample_response, 15, 20)
      draws = SignatureHelp.render(sh, @viewport, @theme)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      max_row = Enum.max(rows)
      assert max_row < 15
    end
  end
end
