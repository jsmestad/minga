defmodule Minga.Test.Storyboard.Model do
  @moduledoc """
  One committed semantic frame, with the facts the storyboard checks read from it.

  `from_ui/1` is pure: it takes the `Minga.RenderModel.UI` that the render pipeline hands both frontends and derives the modeline segment order, the open transient surfaces, the focus owner, which-key entries and the echo line. Nothing here reads pixels or cells, so classification compares semantic models only.

  The raw `ui` stays on the struct for checks that need a field the summary does not carry.
  """

  alias Minga.RenderModel.UI

  @typedoc "A surface that is open in the frame, by its semantic name."
  @type surface ::
          :which_key
          | :picker
          | :minibuffer
          | :completion
          | :signature_help
          | :hover_popup
          | :float_popup
          | :file_tree
          | :agent_chat
          | :empty_state
          | :bottom_panel
          | :edit_timeline
          | :observatory
          | :extension_overlay

  @typedoc "One which-key entry: its key, label and kind."
  @type which_key_entry :: %{key: String.t(), label: String.t(), kind: :command | :group}

  @typedoc "The which-key panel, when open."
  @type which_key :: %{prefix: String.t(), entries: [which_key_entry()]}

  @typedoc "Who owns the keyboard in this frame."
  @type focus :: %{surface: atom(), responder: atom(), window_id: pos_integer()}

  @type t :: %__MODULE__{
          ui: UI.t(),
          theme: MingaEditor.UI.Theme.t() | nil,
          mode: atom(),
          pending_keys: String.t(),
          modeline: [atom()],
          surfaces: [surface()],
          which_key: which_key() | nil,
          focus: focus() | nil,
          echo: String.t() | nil,
          picker_title: String.t() | nil,
          minibuffer_prompt: String.t() | nil
        }

  @enforce_keys [:ui]
  defstruct [
    :ui,
    :theme,
    :which_key,
    :focus,
    :echo,
    :picker_title,
    :minibuffer_prompt,
    mode: :normal,
    pending_keys: "",
    modeline: [],
    surfaces: []
  ]

  @transient [
    :which_key,
    :picker,
    :minibuffer,
    :completion,
    :signature_help,
    :hover_popup,
    :float_popup,
    :extension_overlay
  ]

  @doc """
  Derives the storyboard summary from one semantic UI model.

  `theme` is the editor theme the frame was built with; checks use it to resolve design-token colour roles (`MingaEditor.UI.Theme.role_color/2`).
  """
  @spec from_ui(UI.t(), MingaEditor.UI.Theme.t() | nil) :: t()
  def from_ui(%UI{} = ui, theme \\ nil) do
    data = status_data(ui)

    %__MODULE__{
      ui: ui,
      theme: theme,
      mode: if(data, do: data.mode, else: :normal),
      pending_keys: if(data, do: data.pending_keys || "", else: ""),
      modeline: modeline_order(data),
      surfaces: open_surfaces(ui),
      which_key: which_key(ui.which_key),
      focus: focus(ui.focus_owner),
      echo: data && data.message,
      picker_title: visible_field(ui.picker, :title),
      minibuffer_prompt: visible_field(ui.minibuffer, :prompt)
    }
  end

  @doc "Transient surfaces: the ones that exist to be acted on and closed."
  @spec transient_surfaces() :: [surface()]
  def transient_surfaces, do: @transient

  @doc "True when the surface is open in this frame."
  @spec open?(t(), surface()) :: boolean()
  def open?(%__MODULE__{surfaces: surfaces}, surface), do: surface in surfaces

  @doc "True when any transient surface is open."
  @spec transient_open?(t()) :: boolean()
  def transient_open?(%__MODULE__{surfaces: surfaces}),
    do: Enum.any?(surfaces, &(&1 in @transient))

  @doc "True when a key sequence (leader or prefix) is still pending."
  @spec key_pending?(t()) :: boolean()
  def key_pending?(%__MODULE__{pending_keys: keys}), do: String.trim(keys) != ""

  @doc "A short, stable description of the frame for reports of unclassified states."
  @spec signature(t()) :: String.t()
  def signature(%__MODULE__{} = model) do
    parts =
      [
        "mode=#{model.mode}",
        "focus=#{model.focus && model.focus.surface}",
        "open=#{Enum.join(model.surfaces, "+")}",
        model.which_key && "which_key=#{model.which_key.prefix}",
        model.picker_title && "picker=#{model.picker_title}",
        model.minibuffer_prompt && "prompt=#{model.minibuffer_prompt}",
        key_pending?(model) && "pending=#{String.trim(model.pending_keys)}"
      ]

    parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")
  end

  @spec status_data(UI.t()) :: Minga.RenderModel.UI.StatusBar.Data.t() | nil
  defp status_data(%UI{status_bar: %{data: data}}), do: data
  defp status_data(%UI{}), do: nil

  @doc "The modeline segments as `{name, text, fg}`, left to right."
  @spec modeline_segments(t()) :: [{atom(), String.t(), non_neg_integer()}]
  def modeline_segments(%__MODULE__{ui: ui}) do
    case status_data(ui) do
      %{modeline_segments: %{left: left, right: right}} ->
        for {name, text, fg, _bg, _opts, _target} <- left ++ right,
            do: {segment_name(name), text, fg}

      _ ->
        []
    end
  end

  @spec modeline_order(Minga.RenderModel.UI.StatusBar.Data.t() | nil) :: [atom()]
  defp modeline_order(%{modeline_segments: %{left: left, right: right}}) do
    (left ++ right)
    |> Enum.map(fn segment -> segment |> elem(0) |> segment_name() end)
    |> Enum.dedup()
  end

  defp modeline_order(_data), do: []

  @spec segment_name(atom() | String.t()) :: atom()
  defp segment_name(name) when is_atom(name), do: name
  defp segment_name(name) when is_binary(name), do: String.to_existing_atom(name)

  @spec open_surfaces(UI.t()) :: [surface()]
  defp open_surfaces(%UI{} = ui) do
    [
      which_key: match?(%{visible: true}, ui.which_key),
      picker: visible?(ui.picker),
      minibuffer: visible?(ui.minibuffer),
      completion: visible?(ui.completion),
      signature_help: visible?(ui.signature_help),
      hover_popup: visible?(ui.hover_popup),
      float_popup: visible?(ui.float_popup),
      file_tree: match?(%{status: status} when status != :hidden, ui.file_tree),
      agent_chat: visible?(ui.agent_chat),
      empty_state: visible?(ui.empty_state),
      bottom_panel: visible?(ui.bottom_panel),
      edit_timeline: visible?(ui.edit_timeline),
      observatory: visible?(ui.observatory),
      extension_overlay: visible?(ui.extension_overlay)
    ]
    |> Enum.filter(fn {_surface, open?} -> open? end)
    |> Enum.map(fn {surface, _open?} -> surface end)
  end

  @spec visible?(term()) :: boolean()
  defp visible?(%{visible?: true}), do: true
  defp visible?(_part), do: false

  @spec visible_field(term(), atom()) :: String.t() | nil
  defp visible_field(%{visible?: true} = part, field), do: Map.get(part, field)
  defp visible_field(_part, _field), do: nil

  @spec which_key(Minga.RenderModel.UI.WhichKey.t() | nil) :: which_key() | nil
  defp which_key(%{visible: true, prefix: prefix, bindings: bindings}) do
    %{
      prefix: prefix,
      entries: Enum.map(bindings, &%{key: &1.key, label: &1.description, kind: &1.kind})
    }
  end

  defp which_key(_which_key), do: nil

  @spec focus(Minga.RenderModel.UI.FocusOwner.t() | nil) :: focus() | nil
  defp focus(%{surface: surface, responder: responder, window_id: window_id}),
    do: %{surface: surface, responder: responder, window_id: window_id}

  defp focus(_owner), do: nil
end
