-module(bea_ffi).
-export([
    find_executable/1, run_lines/5, run_inherit/3, run_stderr_lines/5,
    is_tty/0, halt/1, get_env/1, print_stderr/1, print/1, cwd/0,
    read_stdin_all/0, file_mtime/1,
    stdio_binary/0, read_line_bytes/0, read_bytes/1, write_bytes/1,
    open_port_process/3, port_send/2, port_close/1, spawn_stdin_reader/0,
    receive_event/1, monotonic_ms/0, absolute_path/1, init/0, hash/1, split_frames/1,
    foreground_child/0, was_interrupted/0, file_exists/1, no_foreground/0,
    shell_read_line/1, set_cwd/1, prepend_to_path/1,
    shell_code_paths/2, package_dir/1, shell_raw_mode/0, shell_restore_mode/1,
    shell_read_char/0, shell_write/1
]).

init() ->
    _ = io:setopts(standard_io, [{encoding, unicode}]),
    _ = io:setopts(standard_error, [{encoding, unicode}]),
    bea_signal:install(),
    nil.

file_exists(Path) ->
    filelib:is_regular(unicode:characters_to_list(Path)).

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

absolute_path(Path) ->
    unicode:characters_to_binary(filename:absname(unicode:characters_to_list(Path))).

halt(Code) ->
    erlang:halt(Code, [{flush, true}]).

print_stderr(Text) ->
    io:put_chars(standard_error, Text),
    nil.

print(Text) ->
    io:put_chars(standard_io, Text),
    nil.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% Is standard output a terminal?
is_tty() ->
    case io:getopts(standard_io) of
        Opts when is_list(Opts) ->
            proplists:get_value(terminal, Opts, false) =:= true;
        _ -> false
    end.

file_mtime(Path) ->
    case file:read_file_info(unicode:characters_to_list(Path), [{time, posix}]) of
        {ok, Info} -> {ok, element(6, Info)};
        _ -> {error, nil}
    end.

read_stdin_all() ->
    ok = io:setopts(standard_io, [binary]),
    read_stdin_all([]).
read_stdin_all(Acc) ->
    case io:get_chars(standard_io, "", 65536) of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        {error, _} -> unicode:characters_to_binary(lists:reverse(Acc));
        Data -> read_stdin_all([Data | Acc])
    end.

port_opts(Args, Cwd, Extra) ->
    Base = [{args, Args}, exit_status, binary, hide],
    WithCwd = case Cwd of
        <<>> -> Base;
        _ -> [{cd, Cwd} | Base]
    end,
    Extra ++ WithCwd.

%% --- Child processes ----------------------------------------------------------
%%
%% Every program is started through a small `sh` wrapper (WRAPPER) that
%% runs it, waits for it and exits with its status, so the port's OS pid is
%% the wrapper's.
%%
%% - With stock OTP, ports are spawned by `erl_child_setup`, which puts each
%%   child in a session of its own: a Ctrl+C typed in the terminal never
%%   reaches it. With gleepack's runtime, children stay in Bea's session, and
%%   the wrapper puts the program in its own one with `setsid` (when there
%%   is one) so that both runtimes behave the same.
%% - A watcher polls Bea's OS pid. Should Bea die (Ctrl+C without the
%%   launcher's help, `kill -9`, ...), it removes the program: first its
%%   descendants (an Erlang child's own `erl_child_setup` would otherwise
%%   reset the terminal when it goes), then the program itself. Killed with
%%   SIGKILL, nothing gets to reset the terminal behind the shell's back.
%% - Nothing long-lived holds the port's pipes once the program has exited:
%%   gleepack's runtime doesn't close inherited descriptors in children, so
%%   a helper that outlives the program would keep the port open forever.
%%   The watcher is stopped as soon as the program exits.
%% - SIGTERM to the wrapper is forwarded to the program.
%%
%% While a program runs in the foreground this process is registered as
%% `bea_foreground`, so `bea_signal` can forward an interrupt to it.

%% Kill a process tree: $1 is the root. Descendants first, root last; the
%% root is stopped first so nothing new appears meanwhile.
-define(KILL_TREE, <<"
target=$1
kill -0 \"$target\" 2>/dev/null || exit 0
kill -STOP \"$target\" 2>/dev/null
if [ -r /proc/self/stat ]; then
  table=$(cat /proc/[0-9]*/stat 2>/dev/null | awk '{ pid = $1; sub(/^.*\\) /, \"\"); print pid, $2 }')
else
  table=$(ps -A -o pid= -o ppid= 2>/dev/null)
fi
kids=$(printf '%s\\n' \"$table\" | awk -v root=\"$target\" -v self=\"$$\" '
  { if ($1 != self) kids[$2] = kids[$2] \" \" $1 }
  END {
    q[1] = root; h = 1; t = 1
    while (h <= t) {
      n = split(kids[q[h++]], c, \" \")
      for (i = 1; i <= n; i++) if (c[i] != \"\") { print c[i]; q[++t] = c[i] }
    }
  }')
for k in $kids; do kill -KILL \"$k\" 2>/dev/null; done
kill -KILL \"$target\" 2>/dev/null
">>).

%% Arguments: Bea's OS pid, the stdio mode, the KILL_TREE script, then the
%% program and its arguments.
%%   stdio:   the port's pipes are fds 0/1 (the program keeps them)
%%   inherit: the terminal stays on fds 0-2, the port's pipes are fds 3/4
%%   stderr:  like inherit, but the program's stderr goes to the port (fd 4)
%% (An asynchronous command's stdin is /dev/null unless redirected from a
%% descriptor saved beforehand, hence fd 5.)
-define(WRAPPER, <<"bea=$1; mode=$2; kill_tree=$3; shift 3
session() {
  if [ -r \"/proc/$1/stat\" ]; then
    sed 's/^.*) //' \"/proc/$1/stat\" | cut -d' ' -f4
  else
    ps -o sid= -p \"$1\" 2>/dev/null | tr -d ' '
  fi
}
own=
if [ \"$(session $$)\" != \"$$\" ] && command -v setsid >/dev/null 2>&1; then
  own=setsid
fi
exec 5<&0
case $mode in
  stderr) $own \"$@\" <&5 2>&4 3<&- 4>&- 5<&- & ;;
  inherit) $own \"$@\" <&5 3<&- 4>&- 5<&- & ;;
  *) $own \"$@\" <&5 5<&- & ;;
esac
child=$!
exec 5<&-
(
  trap '' INT TERM HUP
  while kill -0 \"$bea\" 2>/dev/null; do
    sleep 0.2 2>/dev/null || sleep 1
  done
  sh -c \"$kill_tree\" bea-kill \"$child\"
) </dev/null >/dev/null 2>&1 3<&- 4>&- &
watcher=$!
trap 'kill -TERM \"$child\" 2>/dev/null' TERM
trap '' INT
while :; do
  wait \"$child\"
  status=$?
  kill -0 \"$child\" 2>/dev/null || break
done
kill -KILL \"$watcher\" 2>/dev/null
exit \"$status\"
">>).

shell() ->
    case os:find_executable("sh") of
        false -> "/bin/sh";
        P -> P
    end.

spawn_wrapped(Mode, Exe, Args, Cwd, Opts) ->
    ShArgs = [<<"-c">>, ?WRAPPER, <<"bea-run">>, os:getpid(), Mode, ?KILL_TREE,
              Exe | Args],
    open_port({spawn_executable, shell()}, port_opts(ShArgs, Cwd, Opts)).

foreground_child() ->
    case whereis(bea_foreground) of
        undefined -> error;
        Pid -> {ok, Pid}
    end.

%% The signal that interrupted a foreground child, if any: {ok, ExitCode}.
was_interrupted() ->
    case persistent_term:get({?MODULE, interrupted}, false) of
        false -> {error, nil};
        sighup -> {ok, 129};
        _ -> {ok, 143}
    end.

%% The language server's children are helpers, not programs the user runs:
%% a SIGTERM (the editor stopping the server) should stop the server at once.
no_foreground() ->
    persistent_term:put({?MODULE, no_foreground}, true),
    nil.

%% Run `Loop(Port)` with this process registered as the foreground owner.
foreground(Port, Exe, Loop) ->
    Registered = case persistent_term:get({?MODULE, no_foreground}, false) of
        true -> false;
        false ->
            try register(bea_foreground, self()) of
                true -> true
            catch error:badarg -> false
            end
    end,
    put(bea_foreground_exe, Exe),
    try Loop(Port)
    after
        case Registered of
            true -> try unregister(bea_foreground) catch _:_ -> ok end;
            false -> ok
        end,
        erase(bea_foreground_exe),
        case erase(bea_kill_timer) of
            undefined -> ok;
            Timer -> erlang:cancel_timer(Timer)
        end,
        % Stopped by an interrupt: whatever it left in its process group goes
        % too (the group id can't be reused while it has members).
        case erase(bea_interrupted_pid) of
            undefined -> ok;
            OsPid -> os:cmd("kill -KILL -" ++ OsPid ++ " 2>/dev/null")
        end,
        flush_late_messages()
    end.

%% An interrupt that arrived just as the child exited still counts (so that
%% `bea run` doesn't go on to start the program); stale kill timers go.
flush_late_messages() ->
    receive
        {bea_force_kill, _} -> flush_late_messages();
        {bea_interrupt, Signal} ->
            persistent_term:put({?MODULE, interrupted}, Signal),
            flush_late_messages()
    after 0 -> ok
    end.

%% Stop the foreground child because Bea was interrupted (the launcher turns
%% Ctrl+C into a SIGTERM for Bea).
%%
%% - An Erlang VM is stopped at once, like Ctrl+C with `+B` would: the BREAK
%%   menu can't work from its own session, and a graceful `init:stop()`
%%   prints noise while `main` is blocked.
%% - Anything else (Node, Gleam, ...) gets a SIGTERM (not SIGINT: children of
%%   a VM started with `+Bi` inherit an ignored SIGINT), and is killed if it is
%%   still there 3 seconds later or on a second interrupt.
%%
%% Killing goes through the watchdog script, so the child's own helpers are
%% gone before it is, and nothing resets the terminal.
interrupt(Port, Signal) ->
    First = persistent_term:get({?MODULE, interrupted}, false) =:= false,
    persistent_term:put({?MODULE, interrupted}, Signal),
    IsErlang = lists:member(filename:basename(unicode:characters_to_list(
                   get_exe())), ["erl", "erl.exe"]),
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> put(bea_interrupted_pid, integer_to_list(Pid));
        _ -> ok
    end,
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} when First, not IsErlang ->
            _ = os:cmd("kill -TERM " ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
            put(bea_kill_timer,
                erlang:send_after(3000, self(), {bea_force_kill, Port}));
        {os_pid, _} -> force_kill(Port);
        _ -> ok
    end.

get_exe() ->
    case get(bea_foreground_exe) of
        undefined -> <<>>;
        Exe -> Exe
    end.

force_kill(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            Cmd = unicode:characters_to_list([<<"exec sh -c '">>, shell_quote(?KILL_TREE),
                   <<"' bea-kill ">>, integer_to_list(OsPid), <<" </dev/null">>]),
            _ = os:cmd(Cmd),
            ok;
        _ -> ok
    end.

%% For use inside single quotes.
shell_quote(Bin) ->
    binary:replace(Bin, <<"'">>, <<"'\\''">>, [global]).

%% Run a program capturing stdout+stderr, calling Fun(State, Line) for every
%% complete line as it arrives. Returns {ExitCode, FinalState}.
run_lines(Exe, Args, Cwd, State, Fun) ->
    Port = spawn_wrapped(<<"stdio">>, Exe, Args, Cwd,
                         [{line, 1048576}, stderr_to_stdout, use_stdio]),
    foreground(Port, Exe, fun(P) -> collect_lines(P, State, Fun, <<>>) end).

collect_lines(Port, State, Fun, Partial) ->
    receive
        {Port, {data, {eol, Chunk}}} ->
            Line = <<Partial/binary, Chunk/binary>>,
            collect_lines(Port, Fun(State, Line), Fun, <<>>);
        {Port, {data, {noeol, Chunk}}} ->
            collect_lines(Port, State, Fun, <<Partial/binary, Chunk/binary>>);
        {Port, {exit_status, Code}} ->
            State1 = case Partial of
                <<>> -> State;
                _ -> Fun(State, Partial)
            end,
            {Code, State1};
        {bea_interrupt, Signal} ->
            interrupt(Port, Signal),
            collect_lines(Port, State, Fun, Partial);
        {bea_force_kill, Port} ->
            force_kill(Port),
            collect_lines(Port, State, Fun, Partial)
    end.

%% Run a program attached to this process' terminal (stdin/stdout/stderr are
%% inherited), so interactive programs and colours just work.
run_inherit(Exe, Args, Cwd) ->
    Port = spawn_wrapped(<<"inherit">>, Exe, Args, Cwd, [nouse_stdio]),
    foreground(Port, Exe, fun wait_exit/1).

wait_exit(Port) ->
    receive
        {Port, {exit_status, Code}} -> Code;
        {bea_interrupt, Signal} ->
            interrupt(Port, Signal),
            wait_exit(Port);
        {bea_force_kill, Port} ->
            force_kill(Port),
            wait_exit(Port);
        {Port, _} -> wait_exit(Port)
    end.

%% Like run_inherit but the child's stderr is captured line by line (through
%% fd 4) so it can be rewritten, while stdin/stdout stay on the terminal.
run_stderr_lines(Exe, Args, Cwd, State, Fun) ->
    Port = spawn_wrapped(<<"stderr">>, Exe, Args, Cwd,
                         [{line, 1048576}, nouse_stdio]),
    foreground(Port, Exe, fun(P) -> collect_lines(P, State, Fun, <<>>) end).

%% --- Raw stdio for the language server ---------------------------------------

stdio_binary() ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    nil.

read_line_bytes() ->
    case io:get_line(standard_io, "") of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Line -> {ok, Line}
    end.

read_bytes(N) ->
    case io:get_chars(standard_io, "", N) of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Data -> {ok, Data}
    end.

write_bytes(Data) ->
    ok = file:write(standard_io, Data),
    nil.

%% A child process speaking over stdio (used to run `gleam lsp`).
open_port_process(Exe, Args, Cwd) ->
    open_port({spawn_executable, Exe},
              port_opts(Args, Cwd, [stream, use_stdio])).

port_send(Port, Data) ->
    try
        port_command(Port, Data),
        true
    catch _:_ -> false
    end.

port_close(Port) ->
    try erlang:port_close(Port) of
        _ -> nil
    catch _:_ -> nil
    end.

%% Spawn a process reading LSP framed messages from stdin and forwarding
%% them to the caller as {stdin_message, Binary} / stdin_closed.
spawn_stdin_reader() ->
    Parent = self(),
    spawn_link(fun() -> stdin_loop(Parent) end),
    nil.

stdin_loop(Parent) ->
    case read_headers(0) of
        {ok, Length} when Length > 0 ->
            case read_exact(Length) of
                {ok, Body} ->
                    Parent ! {stdin_message, Body},
                    stdin_loop(Parent);
                error -> Parent ! stdin_closed
            end;
        {ok, _} -> stdin_loop(Parent);
        error -> Parent ! stdin_closed
    end.

read_headers(Length) ->
    case io:get_line(standard_io, "") of
        eof -> error;
        {error, _} -> error;
        Line ->
            Trimmed = string:trim(Line, both, "\r\n"),
            case Trimmed of
                <<>> -> {ok, Length};
                _ ->
                    case string:split(Trimmed, ":") of
                        [Key, Value] ->
                            case string:lowercase(string:trim(Key)) of
                                <<"content-length">> ->
                                    read_headers(binary_to_integer(string:trim(Value)));
                                _ -> read_headers(Length)
                            end;
                        _ -> read_headers(Length)
                    end
            end
    end.

read_exact(N) -> read_exact(N, []).
read_exact(0, Acc) -> {ok, iolist_to_binary(lists:reverse(Acc))};
read_exact(N, Acc) ->
    case io:get_chars(standard_io, "", N) of
        eof -> error;
        {error, _} -> error;
        Data -> read_exact(N - byte_size(Data), [Data | Acc])
    end.

%% Wait for the next event for the language server main loop.
receive_event(-1) -> receive_event(infinity);
receive_event(Timeout) ->
    receive
        {stdin_message, Body} -> {client_message, Body};
        stdin_closed -> client_closed;
        {Port, {data, Data}} when is_port(Port) -> {server_data, Port, Data};
        {Port, {exit_status, Code}} when is_port(Port) -> {server_exit, Port, Code};
        {'EXIT', _, _} -> receive_event(Timeout);
        _Other -> receive_event(Timeout)
    after Timeout -> timeout
    end.

hash(Term) -> erlang:phash2(Term).

%% Split LSP framed data into complete message bodies and the remainder.
split_frames(Buffer) -> split_frames(Buffer, []).
split_frames(Buffer, Acc) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        nomatch -> {lists:reverse(Acc), Buffer};
        {Pos, 4} ->
            Header = binary:part(Buffer, 0, Pos),
            BodyStart = Pos + 4,
            case content_length(Header) of
                error -> {lists:reverse(Acc), <<>>};
                Length when byte_size(Buffer) - BodyStart >= Length ->
                    Body = binary:part(Buffer, BodyStart, Length),
                    Rest = binary:part(Buffer, BodyStart + Length,
                                       byte_size(Buffer) - BodyStart - Length),
                    split_frames(Rest, [Body | Acc]);
                _ -> {lists:reverse(Acc), Buffer}
            end
    end.

content_length(Header) ->
    Lines = binary:split(Header, <<"\r\n">>, [global]),
    lists:foldl(fun(Line, Acc) ->
        case binary:split(Line, <<":">>) of
            [K, V] ->
                case string:lowercase(string:trim(K)) of
                    <<"content-length">> -> binary_to_integer(string:trim(V));
                    _ -> Acc
                end;
            _ -> Acc
        end
    end, error, Lines).

%% --- `bea shell` ---------------------------------------------------------------

shell_read_line(Prompt) ->
    case io:get_line(standard_io, Prompt) of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Data -> {ok, unicode:characters_to_binary(Data)}
    end.

set_cwd(Path) ->
    _ = file:set_cwd(unicode:characters_to_list(Path)),
    nil.

prepend_to_path(Dir) ->
    Old = case os:getenv("PATH") of false -> ""; P -> P end,
    os:putenv("PATH", unicode:characters_to_list(Dir) ++ ":" ++ Old),
    nil.

%% The shell runs the project's code in Bea's own VM. First every module of
%% Bea and its dependencies (gsh included) is loaded, so they keep working
%% whatever the project brings; then the project's build directories are
%% put in front of the code path. Returns the project modules that can't be
%% loaded because Bea already has a module of that name (e.g. a project
%% `ffi.erl`, the name of gsh's FFI module).
shell_code_paths(BuildDir, Package) ->
    Otp = code:lib_dir(),
    Own = [P || P <- code:get_path(), not lists:prefix(Otp, P), P =/= "."],
    lists:foreach(fun(Dir) ->
        lists:foreach(fun(Beam) ->
            Module = list_to_atom(filename:basename(Beam, ".beam")),
            _ = code:ensure_loaded(Module)
        end, filelib:wildcard(filename:join(Dir, "*.beam")))
    end, Own),
    Base = unicode:characters_to_list(BuildDir),
    Paths = filelib:wildcard(filename:join([Base, "build", "dev", "erlang", "*", "ebin"])),
    lists:foreach(fun(P) -> code:add_patha(P) end, Paths),
    ProjectEbin = filename:join([Base, "build", "dev", "erlang",
                                 unicode:characters_to_list(Package), "ebin"]),
    Clashes = [list_to_binary(filename:basename(B, ".beam"))
               || B <- filelib:wildcard(filename:join(ProjectEbin, "*.beam")),
                  is_clash(list_to_atom(filename:basename(B, ".beam")), B)],
    Clashes.

is_clash(Module, Beam) ->
    case code:is_loaded(Module) of
        {file, Loaded} when is_list(Loaded) ->
            filename:dirname(Loaded) =/= filename:dirname(Beam);
        _ -> false
    end.

%% Directory of a package Bea itself was built with (`.../simplifile`).
package_dir(Name) ->
    case code:lib_dir(binary_to_atom(Name, utf8)) of
        {error, _} -> {error, nil};
        Dir -> {ok, unicode:characters_to_binary(Dir)}
    end.

%% The shell's line editor reads keys in raw mode, which OTP provides with
%% `-noshell` from OTP 28 (`shell:start_interactive({noshell, raw})`; it
%% doesn't deliver input on OTP 27). Elsewhere, or when stdin isn't a
%% terminal, lines are read as they are (`{error, nil}`).
shell_raw_mode() ->
    Otp = list_to_integer(erlang:system_info(otp_release)),
    StdinIsTerminal = case file:read_file_info("/dev/stdin") of
        {ok, Info} -> element(3, Info) =:= device;
        _ -> false
    end,
    case Otp >= 28 andalso StdinIsTerminal of
        false -> {error, nil};
        true ->
            try shell:start_interactive({noshell, raw}) of
                ok -> {ok, <<"raw">>};
                _ -> {error, nil}
            catch _:_ -> {error, nil}
            end
    end.

shell_restore_mode(_) ->
    try shell:start_interactive({noshell, cooked}) of
        _ -> nil
    catch _:_ -> nil
    end.

shell_read_char() ->
    case io:get_chars(standard_io, "", 1) of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        C -> {ok, unicode:characters_to_binary(C)}
    end.

shell_write(Text) ->
    io:put_chars(standard_io, Text),
    nil.
