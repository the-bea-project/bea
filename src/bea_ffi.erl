-module(bea_ffi).
-export([
    find_executable/1, run_lines/5, run_inherit/3, run_stderr_lines/5,
    is_tty/0, halt/1, get_env/1, print_stderr/1, print/1, cwd/0,
    read_stdin_all/0, file_mtime/1,
    stdio_binary/0, read_line_bytes/0, read_bytes/1, write_bytes/1,
    open_port_process/3, port_send/2, port_close/1, spawn_stdin_reader/0,
    receive_event/1, monotonic_ms/0, absolute_path/1, init/0, hash/1, split_frames/1
]).

init() ->
    _ = io:setopts(standard_io, [{encoding, unicode}]),
    _ = io:setopts(standard_error, [{encoding, unicode}]),
    nil.

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

%% Run a program capturing stdout+stderr, calling Fun(State, Line) for every
%% complete line as it arrives. Returns {ExitCode, FinalState}.
run_lines(Exe, Args, Cwd, State, Fun) ->
    Port = open_port({spawn_executable, Exe},
                     port_opts(Args, Cwd, [{line, 1048576}, stderr_to_stdout, use_stdio])),
    collect_lines(Port, State, Fun, <<>>).

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
            {Code, State1}
    end.

%% Run a program attached to this process' terminal (stdin/stdout/stderr are
%% inherited), so interactive programs and colours just work.
run_inherit(Exe, Args, Cwd) ->
    Port = open_port({spawn_executable, Exe}, port_opts(Args, Cwd, [nouse_stdio])),
    wait_exit(Port).

wait_exit(Port) ->
    receive
        {Port, {exit_status, Code}} -> Code;
        {Port, _} -> wait_exit(Port)
    end.

%% Like run_inherit but the child's stderr is captured line by line (through
%% fd 4) so it can be rewritten, while stdin/stdout stay on the terminal.
run_stderr_lines(Exe, Args, Cwd, State, Fun) ->
    Sh = case os:find_executable("sh") of
        false -> "/bin/sh";
        P -> P
    end,
    ShArgs = [<<"-c">>, <<"exec \"$0\" \"$@\" 2>&4">>, Exe | Args],
    Port = open_port({spawn_executable, Sh},
                     port_opts(ShArgs, Cwd, [{line, 1048576}, nouse_stdio])),
    collect_lines(Port, State, Fun, <<>>).

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
