-module(gctop_collect).

-export([start/1, init/1]).

start(Time) ->
    spawn(?MODULE, init, [Time]),
    ok.

init(Time) ->
    Tab = ets:new(?MODULE, [{keypos, 1},protected,{read_concurrency, true}]),
    _ = erlang:trace(all, true, [timestamp, garbage_collection]),
    timer:send_after(Time, stop),
    Info = [{microsec_running, Time*1000}],
    loop(Tab, Info).

loop(Tab, Info) ->
    receive Msg ->
            case Msg of
                stop ->
                    mk_table(Tab, Info),
                    ok;
                {trace_ts, Pid, gc_start, _Stats, TimeStamp} ->
                    ets:insert(Tab, {{Pid, gc}, TimeStamp}),
                    loop(Tab, Info);
                {trace_ts, Pid, gc_end, _Stats, TimeStamp} ->
                    StartKey = {Pid, gc},
                    case ets:lookup(Tab, StartKey) of
                        [] ->
                            loop(Tab, Info);
                        [{_Key, StartTimestamp}] ->
                            ets:delete(Tab, StartKey),
                            TimeDiff = microsec_diff(TimeStamp, StartTimestamp),
                            update_counter(Tab, {Pid, tot_gc}, TimeDiff),
                            loop(Tab, Info)
                    end
            end
    end.

update_counter(Tab, Key, Count) ->
    case ets:lookup(Tab, Key) of
        [] ->
            ets:insert(Tab, {Key, Count});
        [_] ->
            ets:update_counter(Tab, Key, Count)
    end.

mk_table(Tab, Info) ->
    Data = ets:tab2list(Tab),
    FixedData = fix_name(cap(sort(only_total(Data)), 10)),
    to_table(FixedData, Info).

-define(FMT, "~50.50s | ~4.4p~n").

to_table(FixedData, _Info) ->
    io:format(?FMT, [name, time]),
    io:format("~80.80c", [$-]),
    lists:map(
      fun({Name, GcTime}) -> io:format(?FMT, [Name, GcTime]) end,
      FixedData).

only_total(Data) ->
    [{Pid, Time} || {{Pid, tot_gc}, Time} <- Data].

cap(Data, Nr) ->
    lists:sublist(Data, Nr).

sort(Data) ->
    lists:reverse(lists:keysort(2, Data)).

fix_name(Data) ->
    lists:map(fun({Pid, Time}) -> {pid_to_name(Pid), Time} end, Data).

pid_to_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} -> Name;
        _ ->
            case erlang:process_info(Pid, current_function) of
                {current_function, {M,F,A}} ->
                    io_lib:format("~s:~s/~p", [M,F,A]);
                _ ->
                    pid_to_list(Pid)
            end
    end.

microsec_diff({MegaS1, S1, MicroS1}, {MegaS2, S2, MicroS2}) ->
    ((MegaS1-MegaS2)*1000000 + (S1-S2))*1000000 + (MicroS1 - MicroS2).
