defmodule MingaEditor.Extension.Picker.Source do
  @moduledoc """
  Contract for extension-owned pickers opened with `MingaEditor.Extension.Picker.open/3`.

  Every callback that takes `args` receives the original value from `open/3`.
  Candidate and preview callbacks run in background workers without editor state.
  Selection and action callbacks run after the modal closes and return editor state.
  """

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item

  @type page_request :: :start | {:continue, cursor :: term()}
  @type next_page :: :done | {:more, cursor :: term(), presentation :: Item.t()}
  @type preview_segment :: {String.t(), :default | 0..0xFFFFFF, boolean()}
  @type styled_lines :: [[preview_segment()]]
  @type preview :: :none | {:file, Path.t()} | {:lines, styled_lines()} | {:error, String.t()}
  @type action_entry :: {label :: String.t(), action_id :: term()}
  @type shortcut :: {:ctrl, non_neg_integer()}

  @callback title() :: String.t()

  @doc "Returns one page of new items. Only activation of the continuation row requests the next page."
  @callback candidates(args :: term(), page_request()) ::
              {:ok, [Item.t()], next_page()} | {:error, String.t()}

  @doc "Offers a local item when a nonempty query matches no candidate. Must not perform I/O."
  @callback fallback(query :: String.t(), args :: term()) :: Item.t() | nil

  @doc "Confirms a real item, never the continuation row."
  @callback on_select(EditorAPI.state(), Item.t(), args :: term()) :: EditorAPI.state()

  @doc "Supplies a pane preview. File paths must be absolute; `:none` disables content for this item."
  @callback preview(Item.t(), args :: term()) :: preview()

  @doc "Also temporarily displays file previews in the origin editor window without selecting the item."
  @callback live_file_preview?() :: boolean()

  @doc "Offers secondary actions in menu order."
  @callback actions(Item.t(), args :: term()) :: [action_entry()]

  @doc "Resolves a picker shortcut independently of menu eligibility. Currently Ctrl-D is routed."
  @callback shortcut_action(Item.t(), shortcut(), args :: term()) :: term() | nil

  @callback on_action(EditorAPI.state(), action_id :: term(), Item.t(), args :: term()) ::
              EditorAPI.state()

  @optional_callbacks fallback: 2,
                      preview: 2,
                      live_file_preview?: 0,
                      actions: 2,
                      shortcut_action: 3,
                      on_action: 4
end
