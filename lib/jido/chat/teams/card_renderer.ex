defmodule Jido.Chat.Teams.CardRenderer do
  @moduledoc """
  Renders canonical `Jido.Chat.Card` values as Microsoft Adaptive Cards.
  """

  alias Jido.Chat.Card
  alias Jido.Chat.Card.Component
  alias Jido.Chat.Markdown

  @content_type "application/vnd.microsoft.card.adaptive"
  @max_choices 15

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

  @doc "Returns the maximum choice count supported by Teams typeahead controls."
  @spec max_choices() :: pos_integer()
  def max_choices, do: @max_choices

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
    render_choice_set(component, if(kind == :radio_select, do: "expanded", else: "compact"))
  end

  defp render_component(%Component{kind: :external_select} = component) do
    cond do
      component.option_groups != [] ->
        [fallback_block(component, "Teams does not support grouped dynamic choices.")]

      length(component.options) > @max_choices ->
        [
          fallback_block(
            component,
            "Teams supports at most #{@max_choices} choices in a typeahead control."
          )
        ]

      true ->
        component
        |> render_choice_set("filtered")
        |> Enum.map(
          &Map.put(&1, "choices.data", %{
            "type" => "Data.Query",
            "dataset" => component.id
          })
        )
    end
  end

  defp render_component(%Component{kind: :table} = component) do
    visible_rows = Enum.take(component.rows, component.page_size || length(component.rows))
    rows = [component.columns | visible_rows]

    table = %{
      "type" => "Table",
      "columns" => Enum.map(component.columns, fn _column -> %{"width" => 1} end),
      "rows" => Enum.map(rows, &table_row/1),
      "firstRowAsHeader" => true,
      "showGridLines" => true,
      "fallback" => fallback_block(component)
    }

    []
    |> maybe_add_table_caption(component.caption || component.title)
    |> Kernel.++([table])
    |> maybe_add_page_note(length(visible_rows), length(component.rows))
  end

  defp render_component(%Component{kind: :pie_chart} = component) do
    [
      %{
        "type" => "Chart.Pie",
        "title" => component.title,
        "colorSet" => "categorical",
        "data" =>
          Enum.map(component.data, fn point ->
            %{"legend" => point.label, "value" => point.value}
          end),
        "fallback" => fallback_block(component)
      }
      |> compact()
    ]
  end

  defp render_component(%Component{kind: :bar_chart} = component) do
    {type, data} = cartesian_chart_data(component, "Chart.VerticalBar")

    [
      %{
        "type" => type,
        "title" => component.title,
        "colorSet" => "categorical",
        "data" => data,
        "showBarValues" => true,
        "fallback" => fallback_block(component)
      }
      |> compact()
    ]
  end

  defp render_component(%Component{kind: :line_chart} = component) do
    {_type, data} = cartesian_chart_data(component, "Chart.Line")

    [
      %{
        "type" => "Chart.Line",
        "title" => component.title,
        "colorSet" => "categorical",
        "data" => data,
        "fallback" => fallback_block(component)
      }
      |> compact()
    ]
  end

  defp render_component(%Component{kind: :area_chart} = component) do
    [fallback_block(component, "Teams does not support area charts.")]
  end

  defp render_component(%Component{kind: :link} = component) do
    [text_block("[#{component.label || component.text || component.url}](#{component.url})")]
  end

  defp render_component(_component), do: []

  defp render_action(%Component{kind: :link_button} = component) do
    %{
      "type" => "Action.OpenUrl",
      "id" => component.id,
      "title" => component.label || component.title || "Open",
      "url" => component.url
    }
    |> compact()
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

  defp render_choice_set(component, style) do
    [
      %{
        "type" => "Input.ChoiceSet",
        "id" => component.id || "choice",
        "label" => component.label || component.title,
        "style" => style,
        "value" => component.value,
        "choices" => Enum.map(component.options, &render_choice/1)
      }
      |> compact()
    ]
  end

  defp render_choice(option) do
    option = Component.normalize(option)
    %{"title" => option.label || option.text || option.value, "value" => option.value || ""}
  end

  defp cartesian_chart_data(%Component{series: [_ | _]} = component, base_type) do
    data =
      Enum.map(component.series, fn series ->
        %{
          "legend" => series.name,
          "values" =>
            Enum.map(Stream.zip(component.categories, series.values), fn {category, value} ->
              %{"x" => category, "y" => value}
            end)
        }
      end)

    type = if(base_type == "Chart.VerticalBar", do: "Chart.VerticalBar.Grouped", else: base_type)
    {type, data}
  end

  defp cartesian_chart_data(%Component{data: data} = component, "Chart.Line" = type) do
    series =
      data
      |> Enum.group_by(&(&1.series || component.title || "Value"))
      |> Enum.map(fn {legend, points} ->
        %{
          "legend" => legend,
          "values" => Enum.map(points, &%{"x" => &1.label, "y" => &1.value})
        }
      end)

    {type, series}
  end

  defp cartesian_chart_data(%Component{data: data}, type) do
    if Enum.any?(data, &is_binary(&1.series)) do
      grouped =
        data
        |> Enum.group_by(&(&1.series || "Value"))
        |> Enum.map(fn {legend, points} ->
          %{
            "legend" => legend,
            "values" => Enum.map(points, &%{"x" => &1.label, "y" => &1.value})
          }
        end)

      {"Chart.VerticalBar.Grouped", grouped}
    else
      {type, Enum.map(data, &%{"x" => &1.label, "y" => &1.value})}
    end
  end

  defp table_row(values) do
    %{
      "type" => "TableRow",
      "cells" =>
        Enum.map(values, fn value ->
          %{"type" => "TableCell", "items" => [text_block(to_string(value))]}
        end)
    }
  end

  defp maybe_add_table_caption(elements, nil), do: elements

  defp maybe_add_table_caption(elements, caption),
    do: elements ++ [text_block(caption, %{"weight" => "Bolder"})]

  defp maybe_add_page_note(elements, visible_count, total_count)
       when visible_count < total_count do
    elements ++ [text_block("Showing #{visible_count} of #{total_count} rows.")]
  end

  defp maybe_add_page_note(elements, _visible_count, _total_count), do: elements

  defp fallback_block(component, provider_note \\ nil) do
    text =
      component
      |> component_fallback_text()
      |> append_provider_note(provider_note)

    text_block(text)
  end

  defp component_fallback_text(component) do
    %{components: [component]}
    |> Card.new()
    |> Card.fallback_text()
  end

  defp append_provider_note(text, nil), do: text

  defp append_provider_note(text, note),
    do: Enum.join(Enum.reject([text, note], &(&1 in [nil, ""])), "\n")

  defp markdown_text(%Markdown{} = markdown), do: Markdown.stringify(markdown)
  defp markdown_text(value) when is_binary(value), do: value
  defp markdown_text(_value), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
