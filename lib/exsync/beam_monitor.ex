defmodule ExSync.BeamMonitor do
  use GenServer

  @throttle_timeout_ms 100

  defmodule State do
    @enforce_keys [
      :throttle_timer,
      :watcher_pid,
      :unload_set,
      :reload_set
    ]
    defstruct [:throttle_timer, :watcher_pid, :unload_set, :reload_set]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) when is_list(opts) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: ExSync.Config.beam_dirs())
    FileSystem.subscribe(watcher_pid)
    ExSync.Logger.debug("ExSync beam monitor started.")

    state = %State{
      throttle_timer: nil,
      watcher_pid: watcher_pid,
      unload_set: MapSet.new(),
      reload_set: MapSet.new()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    action = action(Path.extname(path), path, events)

    state =
      track_module_change(action, path, state)
      # TODO: Is this correct?
      |> maybe_update_throttle_timer()

    {:noreply, state}
  end

  def handle_info({:file_event, watcher_pid, :stop}, %{watcher_pid: watcher_pid} = state) do
    ExSync.Logger.debug("beam monitor stopped")
    {:noreply, state}
  end

  def handle_info(:throttle_timer_complete, state) do
    state = reload_and_unload_modules(state)
    state = %State{state | throttle_timer: nil}

    {:noreply, state}
  end

  defp action(".beam", path, events) do
    case {:created in events, :removed in events, :modified in events, File.exists?(path)} do
      # update
      {_, _, true, true} -> :reload_module
      # temp file
      {true, true, _, false} -> :nothing
      # remove
      {_, true, _, false} -> :unload_module
      # create and other
      _ -> :nothing
    end
  end

  defp action(_extname, _path, _events), do: :nothing

  defp track_module_change(:nothing, _module, state), do: state

  defp track_module_change(:reload_module, module, state) do
    %State{reload_set: reload_set, unload_set: unload_set} = state

    %State{
      state
      | reload_set: MapSet.put(reload_set, module),
        unload_set: MapSet.delete(unload_set, module)
    }
  end

  defp track_module_change(:unload_module, module, state) do
    %State{reload_set: reload_set, unload_set: unload_set} = state

    %State{
      state
      | reload_set: MapSet.delete(reload_set, module),
        unload_set: MapSet.put(unload_set, module)
    }
  end

  defp maybe_update_throttle_timer(%State{throttle_timer: nil} = state) do
    %State{reload_set: reload_set, unload_set: unload_set} = state

    if Enum.empty?(reload_set) && Enum.empty?(unload_set) do
      state
    else
      # ExSync.Logger.debug("BeamMonitor Start throttle timer")
      throttle_timer = Process.send_after(self(), :throttle_timer_complete, @throttle_timeout_ms)
      %State{state | throttle_timer: throttle_timer}
    end
  end

  defp maybe_update_throttle_timer(state), do: state

  defp reload_and_unload_modules(%State{} = state) do
    %State{reload_set: reload_set, unload_set: unload_set} = state

    reloaded_modules =
      Enum.map(reload_set, fn module_path ->
        {:module, module} = ExSync.Utils.reload(module_path)
        module
      end)

    Enum.each(unload_set, fn module_path ->
      {:module, _module} = ExSync.Utils.unload(module_path)
    end)

    ExSync.Logger.debug("reload complete")

    if callback = ExSync.Config.reload_callback() do
      {mod, fun} = callback
      {:ok, _} = Task.start(mod, fun, [reloaded_modules])
    end

    %State{state | reload_set: MapSet.new(), unload_set: MapSet.new()}
  end
end
