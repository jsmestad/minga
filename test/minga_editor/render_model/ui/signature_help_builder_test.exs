defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature
  alias MingaEditor.RenderModel.UI.SignatureHelpBuilder
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.FontRegistry

  defp ctx(signature_help) do
    state = TestHelpers.base_state()
    shell_state = %{state.shell_runtime.state | signature_help: signature_help}
    intent = Intent.from_editor_state(state)
    intent = %{intent | frame: %{intent.frame | shell_state: shell_state}}

    %Context{
      intent: intent,
      workspace: intent.workspace,
      windows: state.workspace.windows,
      layout: MingaEditor.Layout.compute(state),
      font_registry: FontRegistry.new(),
      message_store: intent.frame.message_store,
      title: "Minga"
    }
  end

  describe "build/1" do
    test "builds hidden signature help for non-Traditional context" do
      intent = Intent.from_editor_state(TestHelpers.base_state())

      model =
        SignatureHelpBuilder.build(%Context{
          intent: %{intent | frame: %{intent.frame | shell_state: :not_traditional}},
          workspace: intent.workspace,
          windows: %MingaEditor.State.Windows{},
          layout: MingaEditor.Layout.compute(TestHelpers.base_state()),
          font_registry: FontRegistry.new(),
          message_store: intent.frame.message_store,
          title: "Minga"
        })

      assert %SignatureHelp{} = model
      refute model.visible?
      assert model.signatures == []
    end

    test "builds hidden signature help when signature_help is nil" do
      model = SignatureHelpBuilder.build(ctx(nil))

      refute model.visible?
      assert model.signatures == []
    end

    test "builds hidden signature help for empty signatures" do
      sh = %MingaEditor.SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      model = SignatureHelpBuilder.build(ctx(sh))

      refute model.visible?
      assert model.signatures == []
    end

    test "builds semantic visible signature help" do
      sh = signature_help()

      model = SignatureHelpBuilder.build(ctx(sh))

      assert model.visible?
      assert model.anchor_row == 10
      assert model.anchor_col == 5
      assert model.active_signature == 0
      assert model.active_parameter == 1

      assert [
               %Signature{
                 label: "foo(a, b)",
                 documentation: "Does foo things",
                 parameters: [
                   %Parameter{label: "a", documentation: "first"},
                   %Parameter{label: "b", documentation: "second"}
                 ]
               }
             ] = model.signatures
    end

    test "clamps active signature and parameter into the rendered model" do
      sh = %MingaEditor.SignatureHelp{
        signatures: [
          %{
            label: "foo(a)",
            documentation: "First",
            parameters: [%{label: "a", documentation: "first"}]
          },
          %{
            label: "bar(x, y)",
            documentation: "Second",
            parameters: [
              %{label: "x", documentation: "first"},
              %{label: "y", documentation: "second"}
            ]
          }
        ],
        active_signature: 99,
        active_parameter: 99,
        anchor_row: 10,
        anchor_col: 5
      }

      model = SignatureHelpBuilder.build(ctx(sh))

      assert model.active_signature == 1
      assert model.active_parameter == 1
    end

    test "rejects the deleted flat map fixture" do
      flat_ctx = %{shell_state: %{signature_help: signature_help()}}

      assert_raise FunctionClauseError, fn ->
        :erlang.apply(SignatureHelpBuilder, :build, [flat_ctx])
      end
    end
  end

  defp signature_help do
    %MingaEditor.SignatureHelp{
      signatures: [
        %{
          label: "foo(a, b)",
          documentation: "Does foo things",
          parameters: [
            %{label: "a", documentation: "first"},
            %{label: "b", documentation: "second"}
          ]
        }
      ],
      active_signature: 0,
      active_parameter: 1,
      anchor_row: 10,
      anchor_col: 5
    }
  end
end
