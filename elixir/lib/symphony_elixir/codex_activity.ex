defmodule SymphonyElixir.CodexActivity do
  @moduledoc """
  Meaningful operator-facing activity feed derived from Codex runtime updates.

  This complements the low-level `last_codex_*` fields used by the existing UI,
  but keeps a short rolling history of useful progress updates for richer
  observability surfaces.
  """

  alias SymphonyElixir.StatusDashboard

  @max_recent_events 60
  @secondary_priority [:blocker, :validation, :decision, :doing_now, :command, :plan]
  @current_activity_kinds [:doing_now, :command, :plan, :blocker]
  @reasoning_methods [
    "item/reasoning/summaryTextDelta",
    "item/reasoning/summaryPartAdded",
    "agent_reasoning"
  ]
  @agent_message_methods [
    "item/agentMessage/delta",
    "agent_message_delta",
    "agent_message_content_delta"
  ]
  @plan_methods ["item/plan/delta", "turn/plan/updated"]
  @command_begin_methods ["exec_command_begin"]
  @command_end_methods ["exec_command_end"]
  @ignored_methods [
    "turn/started",
    "turn/completed",
    "thread/started",
    "thread/tokenUsage/updated",
    "item/started",
    "item/completed",
    "item/commandExecution/outputDelta",
    "item/fileChange/outputDelta",
    "item/reasoning/textDelta",
    "agent_reasoning_delta",
    "reasoning_content_delta",
    "agent_reasoning_section_break",
    "token_count",
    "task_started",
    "user_message",
    "turn_diff",
    "mcp_startup_update",
    "mcp_startup_complete",
    "mcp_tool_call_begin",
    "mcp_tool_call_end",
    "account/updated",
    "account/rateLimits/updated"
  ]
  @stream_reset_after_seconds 2
  @stream_duplicate_window_seconds 1

  @type event_kind :: :doing_now | :decision | :plan | :command | :validation | :blocker

  @type feed_event :: %{
          at: DateTime.t(),
          kind: event_kind(),
          label: String.t(),
          text: String.t(),
          source: String.t(),
          importance: :normal | :high,
          status: :running | :ok | :error | nil,
          streaming: boolean()
        }

  @spec integrate_running_entry(map(), map()) :: map()
  def integrate_running_entry(running_entry, update)
      when is_map(running_entry) and is_map(update) do
    payload = Map.get(update, :payload) || %{}
    method = extract_method(payload)
    timestamp = normalize_timestamp(Map.get(update, :timestamp))

    running_entry = prune_stale_streams(running_entry, timestamp)

    cond do
      stream_category(method) != nil ->
        integrate_stream_update(running_entry, update, payload, method, timestamp)

      method in @command_begin_methods ->
        handle_command_begin(running_entry, update, payload, method, timestamp)

      method in @command_end_methods ->
        handle_command_end(running_entry, update, payload, method, timestamp)

      true ->
        case meaningful_event(update) do
          nil ->
            running_entry

          event ->
            running_entry
            |> Map.put(:last_running_command_text, nil)
            |> apply_event(event)
        end
    end
  end

  @spec recent_events(map()) :: [feed_event()]
  def recent_events(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :recent_codex_events, []) do
      events when is_list(events) -> events
      _ -> []
    end
  end

  @spec current_activity(map()) :: feed_event() | nil
  def current_activity(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :current_activity) do
      %{} = event -> event
      _ -> nil
    end
  end

  @spec latest_meaningful_event(map()) :: feed_event() | nil
  def latest_meaningful_event(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :last_meaningful_update) do
      %{} = event -> event
      _ -> List.first(recent_events(running_entry))
    end
  end

  @spec secondary_update(map()) :: feed_event() | nil
  def secondary_update(running_entry) when is_map(running_entry) do
    events = recent_events(running_entry)

    Enum.find_value(@secondary_priority, fn kind ->
      Enum.find(events, &(&1.kind == kind))
    end) || List.first(events)
  end

  @spec latest_event(map(), [event_kind()]) :: feed_event() | nil
  def latest_event(running_entry, kinds) when is_map(running_entry) and is_list(kinds) do
    Enum.find(recent_events(running_entry), &(&1.kind in kinds))
  end

  @spec meaningful_event(map()) :: feed_event() | nil
  def meaningful_event(update) when is_map(update) do
    payload = Map.get(update, :payload) || %{}
    method = extract_method(payload)
    text = feed_text(update, payload, method)

    case classify(update, method, text) do
      :ignore ->
        nil

      {kind, label, status, importance, streaming} ->
        %{
          at: normalize_timestamp(Map.get(update, :timestamp)),
          kind: kind,
          label: label,
          text: text,
          source: normalize_source(method, Map.get(update, :event)),
          importance: importance,
          status: status,
          streaming: streaming
        }
    end
  end

  defp integrate_stream_update(running_entry, update, payload, method, timestamp) do
    text = feed_text(update, payload, method)
    category = stream_category(method)
    raw_piece = stream_piece(payload, method, text)
    piece = normalize_text(raw_piece)

    cond do
      category == nil or piece == "" ->
        running_entry

      duplicate_stream_piece?(running_entry, category, piece, timestamp) ->
        running_entry

      true ->
        buffer_text =
          running_entry
          |> stream_buffer(category)
          |> append_stream_piece(raw_piece)

        running_entry =
          running_entry
          |> put_stream_buffer(category, buffer_text, timestamp)
          |> put_last_stream_piece(category, piece, timestamp)

        display_text = buffer_display_text(buffer_text)

        if meaningful_stream_text?(display_text) do
          event =
            build_event(%{
              at: timestamp,
              kind: stream_kind(category),
              label: stream_label(category),
              text: display_text,
              source: normalize_source(method, Map.get(update, :event)),
              importance: :normal,
              status: stream_status(category),
              streaming: true
            })

          apply_event(running_entry, event)
        else
          running_entry
        end
    end
  end

  defp handle_command_begin(running_entry, update, payload, method, timestamp) do
    text = feed_text(update, payload, method)

    event =
      build_event(%{
        at: timestamp,
        kind: command_kind(text),
        label: command_label(text),
        text: text,
        source: normalize_source(method, Map.get(update, :event)),
        importance: :normal,
        status: :running,
        streaming: false
      })

    running_entry
    |> Map.put(:last_running_command_text, text)
    |> apply_event(event)
  end

  defp handle_command_end(running_entry, update, payload, method, timestamp) do
    text = command_completion_text(running_entry, update, payload, method)
    status = command_end_status(update)

    event =
      build_event(%{
        at: timestamp,
        kind: command_end_kind(update, text),
        label: command_end_label(update, text),
        text: text,
        source: normalize_source(method, Map.get(update, :event)),
        importance: command_end_importance(update),
        status: status,
        streaming: false
      })

    running_entry
    |> Map.put(:last_running_command_text, nil)
    |> apply_event(event)
  end

  defp build_event(attrs) do
    %{
      at: attrs.at,
      kind: attrs.kind,
      label: attrs.label,
      text: attrs.text,
      source: attrs.source,
      importance: attrs.importance,
      status: attrs.status,
      streaming: attrs.streaming
    }
  end

  defp apply_event(running_entry, event) do
    recent = upsert_recent_event(recent_events(running_entry), event)
    last_meaningful_update = event

    current_activity =
      if event.kind in @current_activity_kinds do
        event
      else
        current_activity(running_entry)
      end

    running_entry
    |> Map.put(:recent_codex_events, recent)
    |> Map.put(:last_meaningful_update, last_meaningful_update)
    |> Map.put(:current_activity, current_activity)
  end

  defp stream_category(method) when method in @agent_message_methods, do: :agent_message
  defp stream_category(method) when method in @reasoning_methods, do: :reasoning_summary
  defp stream_category(method) when method in @plan_methods, do: :plan_update
  defp stream_category(_method), do: nil

  defp stream_kind(:agent_message), do: :doing_now
  defp stream_kind(:reasoning_summary), do: :decision
  defp stream_kind(:plan_update), do: :plan

  defp stream_label(:agent_message), do: "doing now"
  defp stream_label(:reasoning_summary), do: "decision"
  defp stream_label(:plan_update), do: "plan"

  defp stream_status(:agent_message), do: :running
  defp stream_status(:reasoning_summary), do: nil
  defp stream_status(:plan_update), do: :running

  defp stream_buffer(running_entry, category) do
    running_entry
    |> Map.get(:codex_stream_buffers, %{})
    |> Map.get(category)
    |> case do
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end
  end

  defp put_stream_buffer(running_entry, category, text, timestamp) do
    buffers = Map.get(running_entry, :codex_stream_buffers, %{})

    Map.put(
      running_entry,
      :codex_stream_buffers,
      Map.put(buffers, category, %{text: text, updated_at: timestamp})
    )
  end

  defp put_last_stream_piece(running_entry, category, piece, timestamp) do
    pieces = Map.get(running_entry, :codex_last_stream_piece, %{})

    Map.put(
      running_entry,
      :codex_last_stream_piece,
      Map.put(pieces, category, %{text: piece, updated_at: timestamp})
    )
  end

  defp duplicate_stream_piece?(running_entry, category, piece, timestamp) do
    running_entry
    |> Map.get(:codex_last_stream_piece, %{})
    |> Map.get(category)
    |> case do
      %{text: ^piece, updated_at: %DateTime{} = seen_at} ->
        DateTime.diff(timestamp, seen_at, :second) <= @stream_duplicate_window_seconds

      _ ->
        false
    end
  end

  defp prune_stale_streams(running_entry, timestamp) do
    buffers =
      running_entry
      |> Map.get(:codex_stream_buffers, %{})
      |> Enum.reject(fn {_category, %{updated_at: updated_at}} ->
        DateTime.diff(timestamp, updated_at, :second) > @stream_reset_after_seconds
      end)
      |> Map.new()

    pieces =
      running_entry
      |> Map.get(:codex_last_stream_piece, %{})
      |> Enum.reject(fn {_category, %{updated_at: updated_at}} ->
        DateTime.diff(timestamp, updated_at, :second) > @stream_duplicate_window_seconds
      end)
      |> Map.new()

    running_entry
    |> Map.put(:codex_stream_buffers, buffers)
    |> Map.put(:codex_last_stream_piece, pieces)
  end

  defp append_stream_piece(buffer_text, raw_piece) when is_binary(raw_piece) do
    if buffer_text == "" do
      raw_piece
    else
      buffer_text <> raw_piece
    end
  end

  defp buffer_display_text(text) do
    text
    |> strip_feed_prefix()
    |> normalize_text()
  end

  defp meaningful_stream_text?(text) when is_binary(text) do
    cond do
      text == "" -> false
      String.length(text) >= 40 -> true
      sentence_like?(text) and String.length(text) >= 12 -> true
      word_count(text) >= 3 and String.length(text) >= 16 -> true
      true -> false
    end
  end

  defp meaningful_stream_text?(_text), do: false

  defp sentence_like?(text) do
    String.ends_with?(text, [".", "!", "?", ":", ";"])
  end

  defp word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp command_completion_text(running_entry, update, payload, method) do
    completion = feed_text(update, payload, method)
    command_text = Map.get(running_entry, :last_running_command_text)

    case {command_text, command_end_status(update)} do
      {command, :ok} when is_binary(command) and command != "" ->
        truncate_text("#{command} → exit 0")

      {command, :error} when is_binary(command) and command != "" ->
        exit_code =
          map_path(payload, ["params", "msg", "exit_code"]) ||
            map_path(payload, ["params", "msg", "exitCode"])

        if is_integer(exit_code) do
          truncate_text("#{command} → exit #{exit_code}")
        else
          truncate_text("#{command} → failed")
        end

      _ ->
        completion
    end
  end

  defp truncate_text(text, max_len \\ 100) when is_binary(text) do
    if String.length(text) <= max_len do
      text
    else
      String.slice(text, 0, max_len - 1) <> "…"
    end
  end

  defp upsert_recent_event([latest | rest], event) do
    if coalesce?(latest, event) do
      [event | rest]
    else
      [event, latest | rest] |> Enum.take(@max_recent_events)
    end
  end

  defp upsert_recent_event([], event), do: [event]

  defp coalesce?(%{} = latest, %{} = event) do
    latest.streaming and event.streaming and latest.kind == event.kind and
      latest.source == event.source and
      DateTime.diff(event.at, latest.at, :second) <= 5
  end

  defp feed_text(update, payload, method) do
    humanized = humanized_text(update)

    cond do
      method in @agent_message_methods ->
        payload
        |> extract_delta_preview()
        |> fallback_text(strip_feed_prefix(humanized))

      method in @reasoning_methods ->
        payload
        |> extract_reasoning_preview()
        |> fallback_text(strip_feed_prefix(humanized))

      method in @plan_methods ->
        payload
        |> extract_plan_preview()
        |> fallback_text(strip_feed_prefix(humanized))

      true ->
        strip_feed_prefix(humanized)
    end
  end

  defp stream_piece(payload, method, fallback) do
    cond do
      method in @agent_message_methods ->
        payload
        |> extract_delta_preview_raw()
        |> fallback_text(fallback)

      method in @reasoning_methods ->
        payload
        |> extract_reasoning_preview_raw()
        |> fallback_text(fallback)

      method in @plan_methods ->
        payload
        |> extract_plan_preview_raw()
        |> fallback_text(fallback)

      true ->
        fallback
    end
  end

  defp humanized_text(update) do
    StatusDashboard.humanize_codex_message(%{
      event: Map.get(update, :event),
      message: Map.get(update, :payload) || Map.get(update, :raw)
    })
    |> normalize_text()
  end

  defp classify(update, _method, text) do
    event = Map.get(update, :event)

    cond do
      event in [
        :turn_input_required,
        :approval_required,
        :startup_failed,
        :turn_failed,
        :turn_ended_with_error
      ] and
        is_binary(text) and text != "" ->
        {:blocker, "blocker", :error, :high, false}

      true ->
        classify_by_method(update, text)
    end
  end

  defp classify_by_method(update, text) do
    method = extract_method(Map.get(update, :payload) || %{})

    cond do
      is_nil(method) or text == "" ->
        :ignore

      method in @ignored_methods ->
        :ignore

      method in @agent_message_methods and has_preview?(text) ->
        {:doing_now, "doing now", :running, :normal, true}

      method in @reasoning_methods and has_preview?(text) ->
        {:decision, "decision", nil, :normal, true}

      method in @plan_methods ->
        {:plan, "plan", :running, :normal, String.ends_with?(method, "/delta")}

      method in @command_begin_methods ->
        {command_kind(text), command_label(text), :running, :normal, false}

      method in @command_end_methods ->
        {command_end_kind(update, text), command_end_label(update, text),
         command_end_status(update), command_end_importance(update), false}

      method == "item/tool/requestUserInput" ->
        {:blocker, "blocker", :error, :high, false}

      method == "item/commandExecution/requestApproval" ->
        {:blocker, "blocker", :error, :high, false}

      method == "item/fileChange/requestApproval" ->
        {:blocker, "blocker", :error, :high, false}

      method == "tool/requestUserInput" ->
        {:blocker, "blocker", :error, :high, false}

      true ->
        :ignore
    end
  end

  defp command_kind(text) do
    if validation_text?(text), do: :validation, else: :command
  end

  defp command_label(text) do
    if validation_text?(text), do: "validation", else: "command"
  end

  defp command_end_kind(update, text) do
    cond do
      command_end_status(update) == :error -> :blocker
      validation_text?(text) -> :validation
      true -> :command
    end
  end

  defp command_end_label(update, text) do
    cond do
      command_end_status(update) == :error -> "blocker"
      validation_text?(text) -> "validation"
      true -> "command"
    end
  end

  defp command_end_status(update) do
    payload = Map.get(update, :payload) || %{}

    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, ["params", "msg", "exitCode"])

    cond do
      is_integer(exit_code) and exit_code == 0 -> :ok
      is_integer(exit_code) -> :error
      true -> nil
    end
  end

  defp command_end_importance(update) do
    if command_end_status(update) == :error, do: :high, else: :normal
  end

  defp validation_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, [
      "phpunit",
      "mix test",
      "pytest",
      "cargo test",
      "go test",
      "rspec",
      "jest",
      "vitest",
      "lint",
      "diff --check",
      "typecheck",
      "tsc",
      "php -l"
    ])
  end

  defp has_preview?(text) when is_binary(text) do
    String.length(text) >= 4
  end

  defp fallback_text(value, _fallback) when is_binary(value) and value != "", do: value
  defp fallback_text(_value, fallback), do: fallback

  defp extract_delta_preview(payload) do
    payload
    |> extract_delta_preview_raw()
    |> normalize_text()
  end

  defp extract_delta_preview_raw(payload) do
    extract_first_present_raw(payload, [
      ["params", "delta"],
      ["params", "msg", "delta"],
      ["params", "textDelta"],
      ["params", "msg", "textDelta"],
      ["params", "outputDelta"],
      ["params", "msg", "outputDelta"],
      ["params", "text"],
      ["params", "msg", "text"],
      ["params", "content"],
      ["params", "msg", "content"],
      ["params", "msg", "payload", "delta"],
      ["params", "msg", "payload", "text"],
      ["params", "msg", "payload", "content"]
    ])
  end

  defp extract_reasoning_preview(payload) do
    payload
    |> extract_reasoning_preview_raw()
    |> normalize_text()
  end

  defp extract_reasoning_preview_raw(payload) do
    extract_first_present_raw(payload, [
      ["params", "summaryText"],
      ["params", "summary"],
      ["params", "text"],
      ["params", "reason"],
      ["params", "msg", "summaryText"],
      ["params", "msg", "summary"],
      ["params", "msg", "text"],
      ["params", "msg", "reason"],
      ["params", "msg", "payload", "summaryText"],
      ["params", "msg", "payload", "summary"],
      ["params", "msg", "payload", "text"],
      ["params", "msg", "payload", "reason"]
    ])
  end

  defp extract_plan_preview(payload) do
    payload
    |> extract_plan_preview_raw()
    |> normalize_text()
  end

  defp extract_plan_preview_raw(payload) do
    plan =
      map_path(payload, ["params", "plan"]) ||
        map_path(payload, ["params", "steps"]) ||
        map_path(payload, ["params", "items"])

    cond do
      is_list(plan) ->
        plan
        |> Enum.find_value(&plan_entry_text/1)
        |> fallback_text("")

      true ->
        extract_first_present_raw(payload, [
          ["params", "delta"],
          ["params", "msg", "delta"],
          ["params", "text"],
          ["params", "msg", "text"],
          ["params", "content"],
          ["params", "msg", "content"]
        ])
    end
  end

  defp plan_entry_text(%{} = entry) do
    ["text", "title", "content", "summary", "label"]
    |> Enum.find_value(fn key ->
      case map_path(entry, [key]) do
        value when is_binary(value) -> normalize_text(value)
        _ -> nil
      end
    end)
  end

  defp plan_entry_text(entry) when is_binary(entry), do: normalize_text(entry)
  defp plan_entry_text(_entry), do: nil

  defp extract_first_present_raw(payload, paths) do
    Enum.find_value(paths, fn path ->
      case map_path(payload, path) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp strip_feed_prefix(text) when is_binary(text) do
    text
    |> String.replace(~r/^(agent message streaming|agent message content streaming):\s*/i, "")
    |> String.replace(
      ~r/^(reasoning summary streaming|reasoning summary section added|reasoning update|plan streaming|plan updated):\s*/i,
      ""
    )
    |> normalize_text()
  end

  defp strip_feed_prefix(_text), do: ""

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now()

  defp extract_method(%{} = payload) do
    payload
    |> map_value(["method", :method])
    |> normalize_method()
  end

  defp extract_method(_payload), do: nil

  defp normalize_method(<<"codex/event/", suffix::binary>>), do: suffix
  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(_method), do: nil

  defp normalize_source(method, _event) when method in @agent_message_methods, do: "agent_message"
  defp normalize_source(method, _event) when method in @reasoning_methods, do: "reasoning_summary"
  defp normalize_source(method, _event) when method in @plan_methods, do: "plan_update"

  defp normalize_source(method, _event)
       when method in @command_begin_methods or method in @command_end_methods, do: "command"

  defp normalize_source(method, _event) when is_binary(method), do: method
  defp normalize_source(_method, event) when is_atom(event), do: Atom.to_string(event)
  defp normalize_source(_method, event), do: to_string(event)

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(_text), do: ""

  defp map_value(data, keys) when is_map(data) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case fetch_map_key(data, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_value(_data, _keys), do: nil

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp fetch_map_key(data, key) when is_atom(key) do
    cond do
      Map.has_key?(data, key) -> {:ok, Map.get(data, key)}
      Map.has_key?(data, Atom.to_string(key)) -> {:ok, Map.get(data, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_map_key(data, key) when is_binary(key) do
    cond do
      Map.has_key?(data, key) ->
        {:ok, Map.get(data, key)}

      safe_existing_atom?(key) and Map.has_key?(data, String.to_existing_atom(key)) ->
        {:ok, Map.get(data, String.to_existing_atom(key))}

      true ->
        :error
    end
  end

  defp safe_existing_atom?(value) when is_binary(value) do
    try do
      _ = String.to_existing_atom(value)
      true
    rescue
      ArgumentError -> false
    end
  end
end
