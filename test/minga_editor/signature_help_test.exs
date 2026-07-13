defmodule MingaEditor.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.SignatureHelp
  alias MingaEditor.SignatureHelp.Presenter
  alias MingaEditor.UI.Theme

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
      assert Enum.count(sh.signatures) == 2
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
      assert Enum.count(sig.parameters) == 3
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

  describe "box/3" do
    # The cell-grid `render/3` painter was removed in #2311; signature help
    # renders natively via the 0x82 GUI opcode. `box/3` is the live surface that
    # resolves the tooltip's placement rect for the FocusTree/SurfaceRegistry.
    test "returns nil for no signatures" do
      sh = %SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 10,
        anchor_col: 20
      }

      assert Presenter.box(sh, @viewport, @theme) == nil
    end

    test "returns a placement rect within the viewport for a valid signature" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)
      {row, col, w, h} = Presenter.box(sh, @viewport, @theme)

      assert row >= 0 and row + h <= 24
      assert col >= 0 and col + w <= 80
    end

    test "positions above the cursor" do
      sh = SignatureHelp.from_response(@sample_response, 15, 20)
      {row, _col, _w, h} = Presenter.box(sh, @viewport, @theme)

      assert row + h <= 15
    end
  end
end
