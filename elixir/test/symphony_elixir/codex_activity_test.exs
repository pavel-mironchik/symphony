defmodule SymphonyElixir.CodexActivityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexActivity

  test "dedupes equivalent agent message delta sources and waits for meaningful text" do
    now = DateTime.utc_now()

    running_entry =
      blank_running_entry()
      |> CodexActivity.integrate_running_entry(agent_delta_update("item/agentMessage/delta", "Human", now))
      |> CodexActivity.integrate_running_entry(agent_delta_update("agent_message_delta", "Human", now))
      |> CodexActivity.integrate_running_entry(agent_delta_update("agent_message_content_delta", "Human", now))
      |> CodexActivity.integrate_running_entry(agent_delta_update("item/agentMessage/delta", " review", DateTime.add(now, 1, :second)))
      |> CodexActivity.integrate_running_entry(agent_delta_update("agent_message_delta", " review", DateTime.add(now, 1, :second)))
      |> CodexActivity.integrate_running_entry(
        agent_delta_update(
          "agent_message_content_delta",
          " review",
          DateTime.add(now, 1, :second)
        )
      )
      |> CodexActivity.integrate_running_entry(agent_delta_update("item/agentMessage/delta", " blocker", DateTime.add(now, 2, :second)))

    assert [event] = CodexActivity.recent_events(running_entry)
    assert event.kind == :doing_now
    assert event.source == "agent_message"
    assert event.text == "Human review blocker"
    assert CodexActivity.current_activity(running_entry).text == "Human review blocker"
  end

  test "pairs command completion with the most recent command begin" do
    now = DateTime.utc_now()

    running_entry =
      blank_running_entry()
      |> CodexActivity.integrate_running_entry(command_begin_update("git status --short", now))
      |> CodexActivity.integrate_running_entry(command_end_update(0, DateTime.add(now, 1, :second)))

    assert [event | _rest] = CodexActivity.recent_events(running_entry)
    assert event.kind == :command
    assert event.source == "command"
    assert event.text == "git status --short → exit 0"
  end

  defp blank_running_entry do
    %{
      recent_codex_events: [],
      current_activity: nil,
      last_meaningful_update: nil
    }
  end

  defp agent_delta_update(method, delta, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/" <> method,
        "params" => %{"delta" => delta}
      }
    }
  end

  defp command_begin_update(command, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp command_end_update(exit_code, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_end",
        "params" => %{"msg" => %{"exit_code" => exit_code}}
      }
    }
  end
end
