-module(wm_utils).

-export([module_exists/1, messages_in_queue/1, format/2, trail_newline/1, get_unique_id/1, get_env/1, wait_msg/2,
         log_debug_table/1, join_atoms/2, trace_stack/0, uuid/1, wake_up_after/2, nodes_to_names/1, node_to_fullname/1,
         protected_call/2, protected_call/3, get_my_vnode_name/4, get_parent_from_conf/1, get_hostname/1,
         get_module_dir/1, intersection/2, ensure_loaded/1, unroll_symlink/1, get_my_hostname/0, get_my_fqdn/0,
         get_short_name/1, get_address/1, get_job_user/1, is_module_loaded/1, encode_to_binary/1, decode_from_binary/1,
         get_calling_module_name/0, map_to_list/1, terminate_msg/2, match_floats/3, read_file/2, read_stdin/0,
         make_jobs_c_decodable/1, make_nodes_c_decodable/1, is_manager/1, has_role/2, get_behaviour/1, cast/2, await/3,
         await/2]).
-export([do/2, itr/2]).
-export([host_port_uri/1, path_query_uri/1]).
-export([named_substitution/2]).
-export([priv/0, priv/1]).
-export([to_float/1, to_string/1, to_binary/1, to_integer/1]).
-export([localtime/0, now_iso8601/1, timestamp/0, timestamp/1]).

-include("wm_log.hrl").

-define(CALL_TIMEOUT, 10000).
-define(IO_READ_BLOCK_SIZE, 16384).

messages_in_queue(Module) ->
    {messages, Messages} = erlang:process_info(whereis(Module), messages),
    Messages.

trace_stack() ->
    {'EXIT', {_, CallStack}} = (catch 1 = undefined),
    ?LOG_DEBUG("------> TRACE STACK <------~n~p~n------------"
               "--~n",
               [CallStack]).

log_debug_table(Tab) ->
    Iterator =
        fun(Rec, _) ->
           ?LOG_DEBUG("~p", [Rec]),
           []
        end,
    case mnesia:is_transaction() of
        true ->
            mnesia:foldl(Iterator, [], Tab);
        false ->
            Exec = fun({Fun, T}) -> mnesia:foldl(Fun, [], T) end,
            mnesia:activity(transaction, Exec, [{Iterator, Tab}], mnesia_frag)
    end.

get_env(Name) ->
    os:getenv(Name, undefined).

module_exists(Module) ->
    case is_atom(Module) of
        true ->
            try Module:module_info() of
                _InfoList ->
                    true
            catch
                _:_ ->
                    false
            end;
        false ->
            false
    end.

format(Format, MsgParts) when is_list(MsgParts) ->
    io_lib:format(Format, MsgParts);
%io_lib_pretty:print(X, [{depth, -1},{line_length, 1000000}]); % print erlang term in ope line
format(Format, MsgPart) ->
    format(Format, [MsgPart]).

trail_newline(S) ->
    case lists:reverse(S) of
        [$\n | Rest] ->
            lists:reverse(Rest);
        _ ->
            S
    end.

get_unique_id(Len) ->
    ABC = "abcdifghijklmnopqrstuvwxwzABCDIFGHIJKLMNOPQRS"
          "TUVWXYZ1234567890",
    get_random_string(Len, ABC).

get_random_string(Length, AllowedChars) ->
    lists:foldl(fun(_, Acc) ->
                   [lists:nth(
                        random:uniform(length(AllowedChars)), AllowedChars)]
                   ++ Acc
                end,
                [],
                lists:seq(1, Length)).

wait_msg([], _) ->
    ok;
wait_msg(Nodes, Msg) ->
    ?LOG_DEBUG("Waiting (~p) for slave nodes: ~p", [Msg, Nodes]),
    receive
        {Msg, Node} ->
            wait_msg(lists:delete(Node, Nodes), Msg);
        _ ->
            wait_msg(Nodes, Msg)
    end.

join_atoms(Xs, Sep) when is_list(Xs) ->
    List1 = [io_lib:format("~p", [X]) || X <- Xs],
    List2 = io_lib:format("~s", [string:join(List1, Sep)]),
    lists:flatten(List2).

-spec uuid(atom()) -> nonempty_string().
uuid(v4) ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    X = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                      [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    lists:flatten(X).

-spec wake_up_after(pos_integer(), any()) -> reference().
wake_up_after(MilliSeconds, WakeUpMessage) ->
    S = case MilliSeconds of
            X when X < 0 ->
                0;
            _ ->
                MilliSeconds
        end,
    %?LOG_DEBUG("Wake up after ~p ms with message ~p", [S, WakeUpMessage]),
    TRef = erlang:send_after(S, self(), WakeUpMessage).

nodes_to_names(NodeRecords) ->
    do_nodes_to_names(NodeRecords, []).

do_nodes_to_names([], Names) ->
    Names;
do_nodes_to_names([Node | T], Names) ->
    Name = node_to_fullname(Node),
    do_nodes_to_names(T, [Name | Names]).

node_to_fullname({_}) ->
    none;
node_to_fullname({_, _}) ->
    none;
node_to_fullname(Node) ->
    NameStr = wm_entity:get_attr(name, Node),
    HostStr = wm_entity:get_attr(host, Node),
    FullNameStr = NameStr ++ "@" ++ HostStr,
    list_to_atom(FullNameStr).

-spec protected_call(atom() | pid(), term(), term()) -> term().
protected_call(Mod, Msg, Default) ->
    case protected_call(Mod, Msg) of
        {error, _} ->
            Default;
        X ->
            X
    end.

-spec protected_call(atom() | pid(), term()) -> term() | {error, any()}.
protected_call(Mod, Msg) ->
    Ms = wm_conf:g(srv_local_call_timeout, {?CALL_TIMEOUT, integer}),
    %?LOG_DEBUG("gen_server:call(~p, [...], ~p)", [Mod, Ms]),
    try
        gen_server:call(Mod, Msg, Ms)
    catch
        exit:E ->
            trace_stack(),
            ?LOG_ERROR("Protected call to ~p failed: ~p", [Mod, E]),
            {error, E}
    end.

get_short_name({Node, Port}) when is_atom(Node) ->
    {get_short_name(Node), Port};
get_short_name(Node) when is_atom(Node) ->
    get_short_name(atom_to_list(Node));
get_short_name(Node) when is_list(Node) ->
    case lists:any(fun ($@) ->
                           true;
                       (_) ->
                           false
                   end,
                   Node)
    of
        true ->
            [ShortName, _] = string:tokens(Node, "@"),
            ShortName;
        false ->
            Node
    end;
get_short_name(Node) ->
    Node.

get_my_vnode_name(Type1, Type2, NodeName, Host) ->
    case NodeName of
        undefined ->
            {error, unknown};
        VNode ->
            Name =
                case Type1 of
                    long ->
                        Long = VNode ++ "@" ++ Host,
                        case Type2 of
                            string ->
                                Long;
                            atom ->
                                list_to_atom(Long)
                        end;
                    short ->
                        Short = VNode,
                        case Type2 of
                            string ->
                                Short;
                            atom ->
                                list_to_atom(Short)
                        end
                end,
            {ok, Name}
    end.

get_parent_from_conf({NodeName, Host}) ->
    case get_my_vnode_name(short, string, NodeName, Host) of
        {ok, VNode} ->
            case wm_conf:select_node(VNode) of
                {error, need_maint} ->
                    ?LOG_DEBUG("Could not select node from db: ~p", [VNode]),
                    not_found;
                {ok, Node} ->
                    get_parent_from_conf(Node)
            end;
        {error, E2} ->
            ?LOG_ERROR("Could not get my short node name: ~p", [E2]),
            not_found
    end;
get_parent_from_conf(Node) ->
    ParentShortName = wm_entity:get_attr(parent, Node),
    case wm_conf:select_node(ParentShortName) of
        {error, _} ->
            not_found;
        {ok, ParentRec} ->
            wm_conf:get_relative_address(ParentRec, Node)
    end.

get_module_dir(Mod) ->
    filename:dirname(
        code:which(Mod)).

intersection(List1, List2) ->
    [Y || X <- List1, Y <- List2, X == Y].

for_each_line(File, List) ->
    case io:get_line(File, "") of
        eof ->
            file:close(File),
            List;
        Line ->
            F = fun(X) -> re:replace(X, "(^\\s+)|(\\s+$)", "", [global, {return, list}]) end,
            Ws = [F(W) || W <- string:tokens(Line, "=")],
            List2 =
                case length(Ws) == 2 of
                    true ->
                        [{lists:nth(1, Ws), lists:nth(2, Ws)} | List];
                    false ->
                        List
                end,
            for_each_line(File, List2)
    end.

ensure_loaded(Module) ->
    case code:get_mode() of
        embedded ->
            case code:is_loaded(Module) of
                false ->
                    case code:load_file(Module) of
                        {module, Module} ->
                            ?LOG_DEBUG("Module file ~p has been loaded", [Module]);
                        {error, Error} ->
                            ?LOG_ERROR("Could not load ~p: ~p", [Module, Error])
                    end;
                {file, _} ->
                    ok
            end;
        interactive ->
            ok
    end.

unroll_symlink(Path) ->
    case file:read_link(Path) of
        {ok, Filename} ->
            Filename;
        _ ->
            Path
    end.

get_my_hostname() ->
    {ok, Host} = inet:gethostname(),
    Host.

get_my_fqdn() ->
    net_adm:localhost().

get_hostname(NameAtom) when is_atom(NameAtom) ->
    get_hostname(atom_to_list(NameAtom));
get_hostname(Name) when is_list(Name) ->
    case lists:any(fun ($@) ->
                           true;
                       (_) ->
                           false
                   end,
                   Name)
    of
        true ->
            [_, Hostname] = string:tokens(Name, "@"),
            Hostname;
        false ->
            Name
    end.

get_address({error, _}) ->
    not_found;
get_address(not_found) ->
    not_found;
get_address({node, ID}) ->
    [Node] = wm_db:get_one(node, id, ID),
    get_address(Node);
get_address({Type, ID}) when Type =:= grid; Type =:= cluster; Type =:= partition ->
    [Entity] = wm_db:get_one(Type, id, ID),
    Node = wm_entity:get_attr(manager, Entity),
    wm_utils:get_address(Node);
get_address({Host, Port}) when is_integer(Port) ->
    {Host, Port};
get_address(Node) when is_list(Node) ->
    wm_db:get_address(Node);
get_address(Node) when is_atom(Node) ->
    get_address(atom_to_list(Node));
get_address(Node) when is_tuple(Node) ->
    Host = wm_entity:get_attr(host, Node),
    Port = wm_entity:get_attr(api_port, Node),
    {Host, Port}.

is_module_loaded(Module) ->
    lists:any(fun(X) -> X == Module end, erlang:loaded()).

encode_to_binary(Term) when is_binary(Term) ->
    Term;
encode_to_binary(Term) ->
    erlang:term_to_binary(Term).

decode_from_binary(Binary) when is_binary(Binary) ->
    erlang:binary_to_term(Binary).

get_calling_module_name() ->
    Info = erlang:process_info(self()),
    try
        {registered_name, Mod} = lists:keyfind(registered_name, 1, Info),
        Mod
    catch
        _:_ ->
            ?LOG_ERROR("Could not get registered name for process ~p", [self()]),
            noproc
    end.

map_to_list(Map) when is_map(Map) ->
    [{X, map_to_list(Y)} || {X, Y} <- maps:to_list(Map)];
map_to_list(List) when is_list(List) ->
    [map_to_list(X) || X <- List];
map_to_list(NotMapOrList) ->
    NotMapOrList.

terminate_msg(Mod, Reason) ->
    case whereis(wm_log) of
        Pid when is_pid(Pid) ->
            S = case is_list(Reason) of
                    true ->
                        io_lib:format("~s", [lists:flatten(Reason)]);
                    false ->
                        io_lib:format("~p", [Reason])
                end,
            ?LOG_INFO("Terminating ~p with reason: ~p", [Mod, S]);
        _ ->
            ok
    end.

get_job_user(Job) ->
    JobID = wm_entity:get_attr(id, Job),
    UserID = wm_entity:get_attr(user_id, Job),
    ?LOG_DEBUG("User ID: ~p", [UserID]),
    case wm_conf:select(user, {id, UserID}) of
        {error, not_found} ->
            ?LOG_ERROR("User (id=~p) not found, job ~p will "
                       "not be started",
                       [UserID, JobID]),
            {error, not_found};
        {ok, User} ->
            {ok, User}
    end.

-spec match_floats(float(), float(), pos_integer()) -> boolean().
match_floats(X, Y, Depth) ->
    <<AT:Depth/binary, _/binary>> = <<X/float>>,
    <<BT:Depth/binary, _/binary>> = <<Y/float>>,
    AT == BT.

-spec do(any(), [fun((...) -> any() | {break, any()})]) -> any().
do(Arg, []) ->
    Arg;
do(Arg, [Fun | Funs]) ->
    case Fun(Arg) of
        {break, Data} ->
            Data;
        Data ->
            do(Data, Funs)
    end.

-spec itr(pos_integer(), fun((...) -> any() | {break, any()})) -> any().
itr(0, Fun) ->
    Fun();
itr(N, Fun) ->
    case Fun() of
        {break, Data} ->
            Data;
        _Otherwise ->
            itr(N - 1, Fun)
    end.

-spec host_port_uri(nonempty_string() | binary()) -> {string(), non_neg_integer()}.
host_port_uri(URI) when is_binary(URI) ->
    host_port_uri(binary_to_list(URI));
host_port_uri(URI) when is_list(URI) ->
    {ok, {_Scheme, _UserInfo, Host, Port, _Path, _Query}} = http_uri:parse(URI),
    {Host, Port}.

-spec path_query_uri(nonempty_string() | binary()) -> {string(), string()}.
path_query_uri(URI) when is_binary(URI) ->
    path_query_uri(binary_to_list(URI));
path_query_uri(URI) when is_list(URI) ->
    {ok, {_Scheme, _UserInfo, _Host, _Port, Path, Query}} = http_uri:parse(URI),
    {Path, Query}.

-spec named_substitution(string(), #{}) -> binary().
named_substitution(Str, Parameters) ->
    Parts = re:split(Str, "{{ (\\w+) }}", [{return, binary}, group, trim]),
    F = fun ([Word], Acc) ->
                [Word | Acc];
            ([Word, Name], Acc) ->
                [maps:get(Name, Parameters, Name), Word | Acc]
        end,
    list_to_binary(lists:reverse(
                       lists:foldl(F, [], Parts))).

-spec priv() -> string().
priv() ->
    priv("priv").

-spec priv(string()) -> string().
priv(Default) ->
    case code:priv_dir(swm) of
        {error, bad_name} ->
            % This occurs when not running as a release; e.g., erl -pa ebin
            % Of course, this will not work for all cases, but should account
            % for most
            Default;
        PrivDir ->
            % In this case, we are running in a release and the VM knows
            % where the application (and thus the priv directory) resides
            % on the file system
            PrivDir
    end.

-spec to_float(binary() | list()) -> float().
to_float(X) when is_binary(X) ->
    try
        binary_to_float(X)
    catch
        error:badarg ->
            binary_to_integer(X) * 1.0
    end;
to_float(X) when is_list(X) ->
    try
        list_to_float(X)
    catch
        error:badarg ->
            list_to_integer(X) * 1.0
    end;
to_float(X) when is_integer(X) ->
    X * 1.0;
to_float(X) when is_float(X) ->
    X.

-spec to_string(binary() | list()) -> list().
to_string(X) when is_binary(X) ->
    binary_to_list(X);
to_string(X) when is_list(X) ->
    X.

-spec to_binary(binary() | list()) -> binary().
to_binary(X) when is_list(X) ->
    list_to_binary(X);
to_binary(X) when is_binary(X) ->
    X.

-spec to_integer(binary() | list() | integer()) -> integer().
to_integer(X) when is_list(X) ->
    list_to_integer(X);
to_integer(X) when is_binary(X) ->
    binary_to_integer(X);
to_integer(X) when is_integer(X) ->
    X.

-spec localtime() -> tuple().
localtime() ->
    {_, _, Micro} = Now = os:timestamp(),
    {Date, {Hours, Minutes, Seconds}} = calendar:now_to_local_time(Now),
    {Date, {Hours, Minutes, Seconds, Micro div 1000 rem 1000}}.

-spec now_iso8601(atom()) -> list().
now_iso8601(with_ms) ->
    Now = {_, _, MicroSecs} = os:timestamp(),
    {{Y, Mo, D}, {H, M, S}} = calendar:now_to_local_time(Now),
    MilliSeconds = MicroSecs / 1000,
    lists:flatten(
        io_lib:format("~p-~p-~pT~p:~p:~p.~p", [Y, Mo, D, H, M, S, MilliSeconds]));
now_iso8601(without_ms) ->
    {{Y, Mo, D}, {H, M, S}} =
        calendar:now_to_local_time(
            os:timestamp()),
    lists:flatten(
        io_lib:format("~p-~p-~pT~p:~p:~p", [Y, Mo, D, H, M, S])).

-spec timestamp() -> pos_integer().
timestamp() ->
    erlang:system_time().

-spec timestamp(erlang:time_unit()) -> pos_integer().
timestamp(X) ->
    erlang:system_time(X).

-spec read_file(io:device(), list()) -> {atom(), binary() | list()}.
read_file(File, Opts) ->
    {ok, Device} = file:open(File, [read]),
    ok = io:setopts(Device, Opts),
    read_bin_blocks_from_file(File, Device, <<>>).

-spec read_stdin() -> {ok, binary()} | {error, string()}.
read_stdin() ->
    ok = io:setopts(standard_io, [binary]),
    read_bin_blocks_from_file("stdio", standard_io, <<>>).

-spec read_bin_blocks_from_file(string(), term(), binary()) -> {atom(), binary() | string()}.
read_bin_blocks_from_file(File, Device, Acc) ->
    case file:read(Device, ?IO_READ_BLOCK_SIZE) of
        {ok, Data} ->
            read_bin_blocks_from_file(File, Device, <<Acc/bytes, Data/bytes>>);
        {error, enoent} ->
            {error, "File does not exist: " ++ File};
        {error, eacces} ->
            {error, "Missing permission for reading the file: " ++ File};
        {error, eisdir} ->
            {error, "The named file is a directory: " ++ File};
        {error, enotdir} ->
            {error, "A part of the path is not a directory: " ++ File};
        {error, enomem} ->
            {error,
             "Not enough memory to read the whole "
             "file: "
             ++ File};
        {error, Error} when is_atom(Error) ->
            {error, "Could not read " ++ File ++ " (" ++ atom_to_list(Error) ++ ")"};
        eof ->
            {ok, Acc}
    end.

%% @doc Converts jobs to such ones that can be used with  erl_decode()
-spec make_jobs_c_decodable(list()) -> list().
make_jobs_c_decodable(Jobs) ->
    make_jobs_c_decodable(Jobs, []).

%% @doc Converts nodes to such ones that can be used with  erl_decode()
-spec make_nodes_c_decodable(list()) -> list().
make_nodes_c_decodable(Nodes) ->
    make_nodes_c_decodable(Nodes, []).

make_resources_c_decodable(Resources) when is_list(Resources) ->
    F = fun(Res) -> wm_entity:set_attr({prices, []}, Res) end,
    lists:map(F, Resources).

make_jobs_c_decodable([], Result) ->
    Result;
make_jobs_c_decodable([Job | T], Result) ->
    OldRequests = wm_entity:get_attr(request, Job),
    NewRequests = make_resources_c_decodable(OldRequests),
    Job2 = wm_entity:set_attr({request, NewRequests}, Job),
    Job3 =
        wm_entity:set_attr({resources, []},
                           Job2), % not used in C++
    make_jobs_c_decodable(T, [Job3 | Result]).

make_nodes_c_decodable([], Result) ->
    Result;
make_nodes_c_decodable([Node | T], Result) ->
    OldResources = wm_entity:get_attr(resources, Node),
    NewResources = make_resources_c_decodable(OldResources),
    Node2 = wm_entity:set_attr({resources, NewResources}, Node),
    make_nodes_c_decodable(T, [Node2 | Result]).

%% @doc Returns true if self node is a manager one
-spec is_manager(tuple()) -> true | false.
is_manager(Node) ->
    MgrRoles = ["grid", "cluster", "partition"],
    lists:any(fun(Role) -> has_role(Role, Node) end, MgrRoles).

%% @doc Returns true if node record has role assigned
-spec has_role(string(), tuple()) -> true | false.
has_role(RoleName, Node) ->
    RoleIDs = wm_entity:get_attr(roles, Node),
    Roles = wm_conf:select(role, RoleIDs),
    RoleNames = [wm_entity:get_attr(name, Role) || Role <- Roles],
    lists:any(fun(X) -> X == RoleName end, RoleNames).

%% @doc Try to get module behaviour name
-spec get_behaviour(atom() | pid()) -> atom() | not_found.
get_behaviour(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        undefined ->
            not_found;
        {dictionary, []} ->
            not_found;
        {dictionary, D} ->
            case lists:keyfind('$initial_call', 1, D) of
                {'$initial_call', {Module, _, _}} ->
                    get_behaviour(Module);
                _Otherwise ->
                    not_found
            end
    end;
get_behaviour(wm_factory_commit) -> % module name is created dynamically
    gen_server;
get_behaviour(wm_factory_virtres) -> % module name is created dynamically
    gen_server;
get_behaviour(wm_factory_mst) -> % module name is created dynamically
    gen_server;
get_behaviour(wm_factory_proc) -> % module name is created dynamically
    gen_server;
get_behaviour(Module) when is_atom(Module) ->
    List = Module:module_info(),
    case lists:keyfind(attributes, 1, List) of
        {attributes, AttrList} ->
            case lists:keyfind(behaviour, 1, AttrList) of
                {behaviour, [Behaviour]} ->
                    Behaviour;
                _ ->
                    case lists:keyfind(behavior, 1, AttrList) of
                        {behavior, [Behaviour]} ->
                            Behaviour;
                        _ ->
                            not_found
                    end
            end;
        _ ->
            not_found
    end.

%% @doc Send message to a specified process with method that depends on the module's behaviour
-spec cast(pid() | atom(), term()) -> ok.
cast(Process, Msg) ->
    case get_behaviour(Process) of
        gen_server ->
            gen_server:cast(Process, Msg);
        gen_fsm ->
            gen_fsm:send_event(Process, Msg);
        gen_statem ->
            gen_statem:cast(Process, Msg);
        Other -> % process probably has already exited
            ?LOG_DEBUG("No behaviour for ~p found: ~p", [Process, Other]),
            Process ! Msg,
            ok
    end.

%% @doc Waits for a labeled message from reference for Ms number of milliseconds
-spec await(pid() | atom(), atom(), integer()) -> atom().
await(Ref, Label, Ms) ->
    receive
        {Label, Ref, Data} ->
            {Label, Data};
        Otherwise ->
            Otherwise
    after Ms ->
        timeout
    end.

%% @doc Waits for a message from reference for Ms number of milliseconds
-spec await(pid() | atom(), integer()) -> term().
await(Ref, Ms) ->
    receive
        {Ref, ok} ->
            ok;
        Otherwise ->
            Otherwise
    after Ms ->
        timeout
    end.
