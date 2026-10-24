%% Signal handling for the `bea` CLI.
%%
%% Ctrl+C can't be trapped from Erlang: the VM either shows the BREAK menu,
%% halts on the spot (`+B`) or ignores it (`+Bi`). Halting while a child
%% program is still running is what used to corrupt the terminal: the
%% orphaned program (and its `erl_child_setup`) live in their own session, so
%% they never see the Ctrl+C, keep running, and reset the terminal to the
%% mode they saw at start-up whenever they finally exit — long after the
%% shell has put the terminal into its own mode. The shell then sees its
%% own query replies (`^[]11;rgb:...`, `^[[?62;52;c`) echoed back as text.
%%
%% The launcher (`scripts/bea`) therefore starts the VM with `+Bi` and turns
%% Ctrl+C into a SIGTERM for the VM. This handler receives it (SIGHUP too)
%% and forwards it to the child that is running in the foreground, if any,
%% so that `bea` stays alive until the child is gone and only then exits.
%% With nothing running, `bea` simply halts.
-module(bea_signal).
-behaviour(gen_event).

-export([install/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

install() ->
    case whereis(erl_signal_server) of
        undefined -> nil;
        _ ->
            % OTP's default handler (or the one a launcher like gleepack
            % swapped in) would otherwise also act on SIGTERM.
            lists:foreach(fun(H) -> safely(fun() ->
                              gen_event:delete_handler(erl_signal_server, H, [])
                          end) end,
                          gen_event:which_handlers(erl_signal_server)),
            safely(fun() -> gen_event:add_handler(erl_signal_server, ?MODULE, []) end),
            lists:foreach(fun(S) -> safely(fun() -> os:set_signal(S, handle) end) end,
                          [sigterm, sighup]),
            nil
    end.

safely(F) ->
    try F() catch _:_ -> ok end.

init(_) -> {ok, nil}.

handle_event(Signal, State) when Signal =:= sigterm; Signal =:= sighup ->
    case bea_ffi:foreground_child() of
        {ok, Owner} -> Owner ! {bea_interrupt, Signal};
        error ->
            Code = case Signal of
                sigterm -> 143;
                sighup -> 129
            end,
            erlang:halt(Code, [{flush, false}])
    end,
    {ok, State};
handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) -> {ok, ok, State}.
handle_info(_, State) -> {ok, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
