defmodule Jido.Chat.Teams.ModalRenderer do
  @moduledoc """
  Renders canonical modals as Adaptive Cards for Teams dialogs.

  Opening a Teams dialog still needs an invoke activity, so the adapter keeps
  `open_modal/3` unsupported. This renderer builds the native card payload for
  callers that already have that activity context.
  """

  alias Jido.Chat.Modal
  alias Jido.Chat.Modal.Element
  alias Jido.Chat.Teams.CardRenderer

  @doc "Renders a canonical modal as an Adaptive Card."
  @spec render(Modal.t() | map()) :: map()
  def render(%Modal{} = modal) do
    body =
      [%{"type" => "TextBlock", "text" => modal.title, "weight" => "Bolder", "wrap" => true}] ++
        Enum.flat_map(modal.elements, &render_element/1)

    %{
      "$schema" => "https://adaptivecards.io/schemas/adaptive-card.json",
      "type" => "AdaptiveCard",
      "version" => "1.5",
      "body" => body,
      "actions" => [
        %{
          "type" => "Action.Submit",
          "title" => modal.submit_label,
          "data" =>
            compact(%{
              "action_id" => modal.callback_id || modal.id,
              "callback_id" => modal.callback_id || modal.id,
              "private_metadata" => modal.private_metadata
            })
        }
      ]
    }
  end

  def render(modal) when is_map(modal), do: modal |> Modal.new() |> render()

  defp render_element(%Element{kind: :text_input} = element) do
    [
      input_base(element, "Input.Text")
      |> Map.put("isMultiline", element.multiline)
      |> maybe_put("maxLength", element.max_length)
    ] ++ help_blocks(element)
  end

  defp render_element(%Element{kind: :date_input} = element) do
    [
      input_base(element, "Input.Date")
      |> maybe_put("min", element.min_date)
      |> maybe_put("max", element.max_date)
    ] ++ help_blocks(element)
  end

  defp render_element(%Element{kind: :number_input, step: step} = element)
       when not is_nil(step) do
    [fallback_block(element, "Teams Input.Number does not support a step constraint.")]
  end

  defp render_element(%Element{kind: :number_input} = element) do
    [
      input_base(element, "Input.Number")
      |> maybe_put("value", parse_number(element.value))
      |> maybe_put("min", element.min_value)
      |> maybe_put("max", element.max_value)
    ] ++ help_blocks(element)
  end

  defp render_element(%Element{kind: kind} = element) when kind in [:select, :radio_select] do
    [choice_set(element, if(kind == :radio_select, do: "expanded", else: "compact"))] ++
      help_blocks(element)
  end

  defp render_element(%Element{kind: :external_select, option_groups: [_ | _]} = element) do
    [fallback_block(element, "Teams does not support grouped dynamic choices.")]
  end

  defp render_element(%Element{kind: :external_select} = element) do
    if length(element.options) > CardRenderer.max_choices() do
      [
        fallback_block(
          element,
          "Teams supports at most #{CardRenderer.max_choices()} choices in a typeahead control."
        )
      ]
    else
      [
        element
        |> choice_set("filtered")
        |> Map.put("choices.data", %{"type" => "Data.Query", "dataset" => element.id})
      ] ++ help_blocks(element)
    end
  end

  defp render_element(element),
    do: [fallback_block(element, "Teams does not support this input.")]

  defp input_base(element, type) do
    %{
      "type" => type,
      "id" => element.id,
      "label" => element.label,
      "value" => element.value,
      "placeholder" => element.placeholder,
      "isRequired" => element.required,
      "errorMessage" => if(element.required, do: "#{element.label || element.id} is required.")
    }
    |> compact()
  end

  defp choice_set(element, style) do
    input_base(element, "Input.ChoiceSet")
    |> Map.put("style", style)
    |> Map.put("choices", Enum.map(element.options, &choice/1))
  end

  defp choice(option) do
    option = Element.normalize(option)
    %{"title" => option.label || option.value, "value" => option.value || option.id}
  end

  defp fallback_block(element, note) do
    text = Enum.join([element_fallback_text(element), note], "\n")
    %{"type" => "TextBlock", "text" => text, "wrap" => true}
  end

  defp element_fallback_text(element) do
    base = Modal.fallback_text(Modal.new(%{title: "", elements: [element]})) |> String.trim()

    groups =
      Enum.map_join(element.option_groups, " ", fn group ->
        choices = Enum.map_join(group.options, ", ", &(&1.label || &1.value))
        "#{group.label}: #{choices}."
      end)

    Enum.join(Enum.reject([base, groups], &(&1 == "")), " ")
  end

  defp help_blocks(%Element{help_text: nil}), do: []

  defp help_blocks(%Element{help_text: text}),
    do: [%{"type" => "TextBlock", "text" => text, "wrap" => true, "isSubtle" => true}]

  defp parse_number(nil), do: nil

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> parse_float(value)
    end
  end

  defp parse_number(value) when is_number(value), do: value

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
