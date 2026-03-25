defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_issue_identifier, nil)
      |> assign(:selected_issue, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(
       :selected_issue,
       selected_issue_payload(payload, socket.assigns.selected_issue_identifier)
     )
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("select_issue", %{"issue" => issue_identifier}, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue_identifier, issue_identifier)
     |> assign(:selected_issue, selected_issue_payload(socket.assigns.payload, issue_identifier))}
  end

  def handle_event("close_issue_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue_identifier, nil)
     |> assign(:selected_issue, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.running}
                    class={["issue-row", @selected_issue_identifier == entry.issue_identifier && "issue-row-selected"]}
                    phx-click="select_issue"
                    phx-value-issue={entry.issue_identifier}
                  >
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <%= if entry.title do %>
                          <span class="issue-title" title={entry.title}><%= entry.title %></span>
                        <% end %>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"} onclick="event.stopPropagation();">JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="event.stopPropagation(); navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                        <%= if entry.secondary_update do %>
                          <div class="agent-feed-line" title={entry.secondary_update.text}>
                            <span class={agent_feed_badge_class(entry.secondary_update.kind)}>
                              <%= entry.secondary_update.label %>
                            </span>
                            <span class="agent-feed-text"><%= entry.secondary_update.text %></span>
                            <%= if entry.secondary_update.at do %>
                              <span class="agent-feed-at mono"><%= format_event_time(entry.secondary_update.at) %></span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%= if @selected_issue do %>
          <button
            type="button"
            class="issue-panel-backdrop"
            phx-click="close_issue_panel"
            aria-label="Close issue details"
          >
          </button>

          <aside class="issue-panel" aria-label="Issue details">
            <div class="issue-panel-header">
              <div class="issue-panel-heading">
                <p class="eyebrow">Issue details</p>
                <h2 class="issue-panel-title"><%= @selected_issue.issue_identifier %></h2>
                <%= if @selected_issue.title do %>
                  <p class="issue-panel-copy"><%= @selected_issue.title %></p>
                <% end %>
              </div>

              <button type="button" class="subtle-button issue-panel-close" phx-click="close_issue_panel">
                Close
              </button>
            </div>

            <div class="issue-panel-body">
              <section class="issue-panel-section">
                <div class="issue-panel-meta">
                  <span class={state_badge_class(@selected_issue.state)}><%= @selected_issue.state %></span>
                  <span class="muted">Runtime <%= format_runtime_and_turns(@selected_issue.started_at, @selected_issue.turn_count, @now) %></span>
                  <span class="muted">Tokens <%= format_int(@selected_issue.tokens.total_tokens) %></span>
                </div>
                <div class="issue-panel-links">
                  <%= if @selected_issue.issue_url do %>
                    <a class="issue-link" href={@selected_issue.issue_url} target="_blank" rel="noreferrer">Linear</a>
                  <% end %>
                  <a class="issue-link" href={"/api/v1/#{@selected_issue.issue_identifier}"} target="_blank" rel="noreferrer">JSON details</a>
                  <%= if @selected_issue.workspace_path do %>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy workspace"
                      data-copy={@selected_issue.workspace_path}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy workspace
                    </button>
                  <% end %>
                  <%= if @selected_issue.session_id do %>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy session"
                      data-copy={@selected_issue.session_id}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy session
                    </button>
                  <% end %>
                </div>
              </section>

              <section class="issue-panel-section">
                <div class="issue-panel-section-header">
                  <h3 class="section-title">Current status</h3>
                  <p class="section-copy">Short operator-facing summary of what the agent is doing.</p>
                </div>
                <div class="issue-summary-grid">
                  <article class="issue-summary-card">
                    <p class="metric-label">Now</p>
                    <%= if @selected_issue.current_activity do %>
                      <div class="summary-event-stack">
                        <span class={agent_feed_badge_class(@selected_issue.current_activity.kind)}><%= @selected_issue.current_activity.label %></span>
                        <p class="summary-event-text"><%= @selected_issue.current_activity.text %></p>
                      </div>
                    <% else %>
                      <p class="muted">No current activity yet.</p>
                    <% end %>
                  </article>

                  <article class="issue-summary-card">
                    <p class="metric-label">Latest meaningful update</p>
                    <%= if @selected_issue.last_meaningful_update do %>
                      <div class="summary-event-stack">
                        <span class={agent_feed_badge_class(@selected_issue.last_meaningful_update.kind)}><%= @selected_issue.last_meaningful_update.label %></span>
                        <p class="summary-event-text"><%= @selected_issue.last_meaningful_update.text %></p>
                      </div>
                    <% else %>
                      <p class="muted">No meaningful updates yet.</p>
                    <% end %>
                  </article>

                  <article class="issue-summary-card">
                    <p class="metric-label">Last command</p>
                    <%= if @selected_issue.last_command do %>
                      <div class="summary-event-stack">
                        <span class={agent_feed_badge_class(@selected_issue.last_command.kind)}><%= @selected_issue.last_command.label %></span>
                        <p class="summary-event-text"><%= @selected_issue.last_command.text %></p>
                      </div>
                    <% else %>
                      <p class="muted">No command activity captured.</p>
                    <% end %>
                  </article>

                  <article class="issue-summary-card">
                    <p class="metric-label">Last validation / blocker</p>
                    <%= cond do %>
                      <% @selected_issue.last_blocker -> %>
                        <div class="summary-event-stack">
                          <span class={agent_feed_badge_class(@selected_issue.last_blocker.kind)}><%= @selected_issue.last_blocker.label %></span>
                          <p class="summary-event-text"><%= @selected_issue.last_blocker.text %></p>
                        </div>
                      <% @selected_issue.last_validation -> %>
                        <div class="summary-event-stack">
                          <span class={agent_feed_badge_class(@selected_issue.last_validation.kind)}><%= @selected_issue.last_validation.label %></span>
                          <p class="summary-event-text"><%= @selected_issue.last_validation.text %></p>
                        </div>
                      <% true -> %>
                        <p class="muted">No validation or blockers yet.</p>
                    <% end %>
                  </article>
                </div>
              </section>

              <section class="issue-panel-section">
                <div class="issue-panel-section-header">
                  <h3 class="section-title">Live feed</h3>
                  <p class="section-copy">Recent meaningful agent updates only; system chatter remains in the original Codex update field.</p>
                </div>

                <%= if @selected_issue.recent_events == [] do %>
                  <p class="empty-state">No meaningful feed entries yet.</p>
                <% else %>
                  <div class="feed-timeline">
                    <article class="feed-event" :for={event <- @selected_issue.recent_events}>
                      <div class="feed-event-time mono"><%= format_event_time(event.at) %></div>
                      <div class="feed-event-body">
                        <div class="feed-event-header">
                          <span class={agent_feed_badge_class(event.kind)}><%= event.label %></span>
                          <%= if event.status do %>
                            <span class={["feed-status", "feed-status-#{event.status}"]}><%= event.status %></span>
                          <% end %>
                        </div>
                        <p class="feed-event-text"><%= event.text %></p>
                      </div>
                    </article>
                  </div>
                <% end %>
              </section>
            </div>
          </aside>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp agent_feed_badge_class(kind) do
    base = "agent-feed-badge"

    case to_string(kind) do
      "blocker" -> "#{base} agent-feed-badge-blocker"
      "validation" -> "#{base} agent-feed-badge-validation"
      "decision" -> "#{base} agent-feed-badge-decision"
      "doing_now" -> "#{base} agent-feed-badge-doing-now"
      "command" -> "#{base} agent-feed-badge-command"
      "plan" -> "#{base} agent-feed-badge-plan"
      _ -> base
    end
  end

  defp selected_issue_payload(_payload, nil), do: nil

  defp selected_issue_payload(payload, issue_identifier) when is_binary(issue_identifier) do
    Enum.find(payload.running, &(&1.issue_identifier == issue_identifier))
  end

  defp selected_issue_payload(_payload, _issue_identifier), do: nil

  defp format_event_time(nil), do: nil

  defp format_event_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_event_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _offset} -> format_event_time(parsed)
      _ -> datetime
    end
  end

  defp format_event_time(other), do: to_string(other)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
