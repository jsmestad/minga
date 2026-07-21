defmodule MingaEditor.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.SignatureHelp
  alias MingaEditor.SignatureHelp.Presenter
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

  describe "exact lifecycle values" do
    test "replacement and dismissal reject legacy values" do
      signature_help = SignatureHelp.from_response(@sample_response, 10, 20)
      assert SignatureHelp.replace(nil, signature_help) == signature_help
      assert SignatureHelp.dismiss(signature_help) == nil

      assert_raise FunctionClauseError, fn ->
        invoke(SignatureHelp, :replace, [%{}, signature_help])
      end

      assert_raise FunctionClauseError, fn ->
        invoke(SignatureHelp, :replace, [nil, %{}])
      end

      assert_raise FunctionClauseError, fn -> invoke(SignatureHelp, :dismiss, [%{}]) end
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

  describe "box/2" do
    # The cell-grid `render/3` painter was removed in #2311; signature help
    # renders natively via the 0x82 GUI opcode. `box/2` is the live surface that
    # resolves the tooltip's placement rect for the FocusTree/SurfaceRegistry.
    test "returns nil for no signatures" do
      sh = %SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 10,
        anchor_col: 20
      }

      assert Presenter.box(sh, @viewport) == nil
    end

    test "returns the exact conservative rect for active parameter documentation" do
      sh = SignatureHelp.from_response(@sample_response, 10, 20)

      assert Presenter.box(sh, @viewport) == {5, 20, 32, 5}
    end

    test "uses minimal height when the active parameter has no documentation" do
      response = %{
        "signatures" => [
          %{
            "label" => "foo(bar)",
            "parameters" => [
              %{"label" => "bar", "documentation" => ""}
            ]
          }
        ],
        "activeSignature" => 0,
        "activeParameter" => 0
      }

      sh = SignatureHelp.from_response(response, 4, 3)

      assert Presenter.box(sh, @viewport) == {1, 3, 32, 3}
    end
  end

  # The indirection lets runtime boundary tests pass intentionally invalid typed values.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp invoke(module, function, arguments), do: apply(module, function, arguments)
end
