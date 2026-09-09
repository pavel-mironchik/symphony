defmodule SymphonyElixir.TerminalEventTest do
  use SymphonyElixir.TestSupport

  for method <- ["turn/completed", "turn/failed", "turn/cancelled"],
      {identity, params} <- [
        {"child thread", %{"threadId" => "child", "turn" => %{"id" => "turn-main"}}},
        {"old turn", %{"threadId" => "thread-main", "turn" => %{"id" => "old"}}},
        {"flat child turn", %{"threadId" => "child", "turnId" => "turn-main"}},
        {"missing thread", %{"turn" => %{"id" => "turn-main"}}},
        {"missing turn", %{"threadId" => "thread-main"}},
        {"no identity", %{}}
      ] do
    @method method
    @params params
    test "#{method} from #{identity} does not settle the main turn" do
      foreign = %{"method" => @method, "params" => Map.put(@params, "error", %{"message" => "token_expired"})}
      parent = self()

      assert {:ok, %{thread_id: "thread-main", turn_id: "turn-main"}} =
               run_stream([foreign, tool_request()], terminal("completed"),
                 tool_executor: fn "probe", %{} ->
                   send(parent, :main_still_running)
                   %{success: true, contentItems: []}
                 end,
                 on_message: fn message -> send(parent, {:event, message}) end
               )

      assert_received :main_still_running
      assert_received {:event, %{event: :notification, payload: ^foreign}}
      assert_received {:event, %{event: :turn_completed}}
      refute_received {:event, %{event: :turn_failed}}
      refute_received {:event, %{event: :turn_cancelled}}
      refute_received {:event, %{event: :auth_failure}}
    end
  end

  test "matching completed status failed is an error" do
    assert {:error, {:turn_failed, _}} = run_stream([terminal("failed")])
  end

  test "matching completed status interrupted is cancellation" do
    assert {:error, {:turn_cancelled, _}} = run_stream([terminal("interrupted")])
  end

  test "matching failed completion preserves authentication failure classification" do
    payload = put_in(terminal("failed"), ["params", "turn", "error"], %{"message" => "token_expired"})
    assert {:error, {:auth_failed, _}} = run_stream([payload])
  end

  test "fragmented child notification does not lose the expected turn identity" do
    foreign = put_in(terminal("completed"), ["params", "threadId"], "child")
    foreign = put_in(foreign, ["params", "padding"], String.duplicate("x", 1_100_000))
    assert {:ok, _} = run_stream([foreign, terminal("completed")])
  end

  test "runner counts only parent turns across interleaved child events and approval" do
    test_root = Path.join(System.tmp_dir!(), "symphony-runner-scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)
    binary = Path.join(test_root, "fake-codex")
    receipt = Path.join(test_root, "parent-completed")
    foreign = put_in(terminal("completed"), ["params", "threadId"], "child")

    File.write!(binary, """
    #!/bin/sh
    read -r line
    printf '%s\\n' '{"id":1,"result":{}}'
    read -r line
    read -r line
    printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-main"}}}'
    read -r line
    printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
    #{Enum.map_join(1..20, "\n", fn _ -> emit(foreign) end)}
    printf '%s\\n' '{"id":42,"method":"item/commandExecution/requestApproval","params":{}}'
    read -r line
    printf '%s\\n' "$line" > '#{receipt}'
    #{emit(terminal("completed"))}
    read -r line
    printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-next"}}}'
    #{emit(terminal("completed"))}
    #{emit(put_in(terminal("completed"), ["params", "turn", "id"], "turn-next"))}
    while read -r line; do :; done
    """)

    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      codex_command: binary,
      codex_approval_policy: "never",
      codex_turn_timeout_ms: 1_000
    )

    issue = %Issue{id: "scope", identifier: "MT-SCOPE", title: "Terminal scope", state: "In Progress", dispatchable: true}
    parent = self()

    fetcher = fn ["scope"] ->
      assert File.read!(receipt) |> Jason.decode!() == %{"id" => 42, "result" => %{"decision" => "acceptForSession"}}
      send(parent, :parent_finished)
      {:ok, [issue]}
    end

    assert :ok = AgentRunner.run(issue, self(), max_turns: 2, issue_state_fetcher: fetcher)
    assert_received :parent_finished
    assert_received :parent_finished
    refute_received :parent_finished
  end

  for method <- ["turn/failed", "turn/cancelled"] do
    @method method
    test "matching legacy #{@method} with flat identity is terminal" do
      params = %{"threadId" => "thread-main", "turnId" => "turn-main"}
      expected = if @method == "turn/failed", do: :turn_failed, else: :turn_cancelled
      assert {:error, {^expected, ^params}} = run_stream([%{"method" => @method, "params" => params}])
    end
  end

  test "foreign completion followed by silence times out rather than succeeding" do
    assert {:error, :turn_timeout} =
             run_stream([%{"method" => "turn/completed", "params" => %{}}])
  end

  defp terminal(status) do
    %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "thread-main",
        "turn" => %{"id" => "turn-main", "status" => status}
      }
    }
  end

  defp tool_request do
    %{
      "id" => 42,
      "method" => "item/tool/call",
      "params" => %{"threadId" => "thread-main", "turnId" => "turn-main", "tool" => "probe", "arguments" => %{}}
    }
  end

  defp run_stream(events, after_tool \\ nil, opts \\ []) do
    test_root = Path.join(System.tmp_dir!(), "symphony-terminal-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-SCOPE")
    binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    File.write!(binary, """
    #!/bin/sh
    read -r line
    printf '%s\\n' '{"id":1,"result":{}}'
    read -r line
    read -r line
    printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-main"}}}'
    read -r line
    printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
    #{Enum.map_join(events, "\n", &emit/1)}
    read -r line
    #{if after_tool, do: emit(after_tool), else: ""}
    while read -r line; do :; done
    """)

    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: binary,
      codex_turn_timeout_ms: 500
    )

    issue = %Issue{id: "scope", identifier: "MT-SCOPE", title: "Terminal scope", state: "In Progress"}
    AppServer.run(workspace, "test", issue, opts)
  end

  defp emit(payload), do: "printf '%s\\n' '#{Jason.encode!(payload)}'"
end
