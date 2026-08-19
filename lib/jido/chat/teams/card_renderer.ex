defmodule Jido.Chat.Teams.CardRenderer do
  @moduledoc """
  Renders canonical `Jido.Chat.Card` values as Microsoft Adaptive Cards.
  """

  alias Jido.Chat.Card
  alias Jido.Chat.Card.Component
  alias Jido.Chat.Markdown

  @content_type "application/vnd.microsoft.card.adaptive"

  @doc "Returns the Bot Connector attachment content type."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc "Renders a canonical or raw Adaptive Card."
  @spec render(Card.t() | map()) :: map()
  def render(%{"type" => "AdaptiveCard"} = card), do: card
  def render(%{type: "AdaptiveCard"} = card), do: stringify_keys(card)

  def render(%Card{} = card) do
    body =
      []
      |> maybe_add_text(card.title, %{size: "Large", weight: "Bolder"})
      |> maybe_add_text(card.summary, %{wrap: true})
      |> maybe_add_markdown(card.markdown)
      |> Kernel.++(Enum.flat_map(card.components, &render_component/1))

    %{
      "$schema" => "https://adaptivecards.io/schemas/adaptive-card.json",
      "type" => "AdaptiveCard",
      "version" => "1.5",
      "body" => body
    }
  end

  def render(card) when is_map(card) do
    card
    |> Card.normalize()
    |> render()
  end

  defp render_component(%Component{kind: :text} = component) do
    [text_block(component.text || markdown_text(component.markdown))]
  end

  defp render_component(%Component{kind: :section} = component) do
    content = component.title || component.text || markdown_text(component.markdown)
    [text_block(content, %{"weight" => if(component.title, do: "Bolder", else: "Default")})]
  end

  defp render_component(%Component{kind: :field} = component) do
    [
      %{
        "type" => "FactSet",
        "facts" => [%{"title" => component.label || "", "value" => component.text || ""}]
      }
    ]
  end

  defp render_component(%Component{kind: :fields} = component) do
    facts =
      Enum.map(component.items, fn item ->
        item = Component.normalize(item)
        %{"title" => item.label || item.title || "", "value" => item.text || item.value || ""}
      end)

    [%{"type" => "FactSet", "facts" => facts}]
  end

  defp render_component(%Component{kind: :actions} = component) do
    actions = component.items |> Enum.map(&Component.normalize/1) |> Enum.map(&render_action/1)
    [%{"type" => "ActionSet", "actions" => actions}]
  end

  defp render_component(%Component{kind: kind} = component)
       when kind in [:button, :link_button] do
    [%{"type" => "ActionSet", "actions" => [render_action(component)]}]
  end

  defp render_component(%Component{kind: :image} = component) do
    [
      %{
        "type" => "Image",
        "url" => component.image_url,
        "altText" => component.alt_text || component.title || ""
      }
    ]
  end

  defp render_component(%Component{kind: :divider}) do
    [%{"type" => "TextBlock", "text" => " ", "separator" => true, "spacing" => "Small"}]
  end

  defp render_component(%Component{kind: kind} = component)
       when kind in [:select, :radio_select] do
    choices =
      Enum.map(component.options, fn option ->
        option = Component.normalize(option)
        %{"title" => option.label || option.text || option.value, "value" => option.value || ""}
      end)

    [
      %{
        "type" => "Input.ChoiceSet",
        "id" => component.id || "choice",
        "label" => component.label || component.title,
        "style" => if(kind == :radio_select, do: "expanded", else: "compact"),
        "choices" => choices
      }
      |> compact()
    ]
  end

  defp render_component(%Component{kind: :table} = component) do
    header = Enum.join(component.columns, " | ")
    rows = Enum.map_join(component.rows, "\n", &Enum.join(&1, " | "))
    [text_block(Enum.join(Enum.reject([header, rows], &(&1 == "")), "\n"))]
  end

  defp render_component(%Component{kind: :link} = component) do
    [text_block("[#{component.label || component.text || component.url}](#{component.url})")]
  end

  defp render_component(_component), do: []

  defp render_action(%Component{kind: :link_button} = component) do
    %{
      "type" => "Action.OpenUrl",
      "title" => component.label || component.title || "Open",
      "url" => component.url
    }
  end

  defp render_action(%Component{} = component) do
    %{
      "type" => "Action.Submit",
      "title" => component.label || component.title || "Submit",
      "data" =>
        %{
          "action_id" => component.id,
          "value" => component.value
        }
        |> compact()
    }
  end

  defp maybe_add_text(body, nil, _attrs), do: body
  defp maybe_add_text(body, "", _attrs), do: body
  defp maybe_add_text(body, text, attrs), do: body ++ [text_block(text, stringify_keys(attrs))]

  defp maybe_add_markdown(body, nil), do: body
  defp maybe_add_markdown(body, markdown), do: body ++ [text_block(markdown_text(markdown))]

  defp text_block(text, attrs \\ %{}) do
    %{"type" => "TextBlock", "text" => text || "", "wrap" => true}
    |> Map.merge(attrs)
  end

  defp markdown_text(%Markdown{} = markdown), do: Markdown.stringify(markdown)
  defp markdown_text(value) when is_binary(value), do: value
  defp markdown_text(_value), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
