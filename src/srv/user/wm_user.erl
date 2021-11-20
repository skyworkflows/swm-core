-module(wm_user).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("../../lib/wm_log.hrl").
-include("../../lib/wm_entity.hrl").
-include("../../../include/wm_scheduler.hrl").

-record(mstate, {spool = "" :: string}).

%% ============================================================================
%% API
%% ============================================================================

-spec start_link([term()]) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% ============================================================================
%% Callbacks
%% ============================================================================

-spec init(term()) -> {ok, term()} | {ok, term(), hibernate | infinity | non_neg_integer()} | {stop, term()} | ignore.
-spec handle_call(term(), term(), term()) ->
                     {reply, term(), term()} |
                     {reply, term(), term(), hibernate | infinity | non_neg_integer()} |
                     {noreply, term()} |
                     {noreply, term(), hibernate | infinity | non_neg_integer()} |
                     {stop, term(), term()} |
                     {stop, term(), term(), term()}.
-spec handle_cast(term(), term()) ->
                     {noreply, term()} |
                     {noreply, term(), hibernate | infinity | non_neg_integer()} |
                     {stop, term(), term()}.
-spec handle_info(term(), term()) ->
                     {noreply, term()} |
                     {noreply, term(), hibernate | infinity | non_neg_integer()} |
                     {stop, term(), term()}.
-spec terminate(term(), term()) -> ok.
-spec code_change(term(), term(), term()) -> {ok, term()}.
init(Args) ->
    ?LOG_INFO("Load user management service"),
    process_flag(trap_exit, true),
    wm_event:subscribe(http_started, node(), ?MODULE),
    MState = parse_args(Args, #mstate{}),
    {ok, MState}.

handle_call({show, JIDs}, _From, MState) ->
    {reply, handle_request(show, JIDs, MState), MState};
handle_call({requeue, JIDs}, _From, MState) ->
    {reply, handle_request(requeue, JIDs, MState), MState};
handle_call({cancel, JIDs}, _From, MState) ->
    {reply, handle_request(cancel, JIDs, MState), MState};
handle_call({submit, JobScriptContent, Filename, Username}, _From, MState) ->
    {reply, handle_request(submit, {JobScriptContent, Filename, Username}, MState), MState};
handle_call({list, TabList}, _From, MState) ->
    {reply, handle_request(list, TabList, MState), MState};
handle_call({list, TabList, Limit}, _From, MState) ->
    {reply, handle_request(list, {TabList, Limit}, MState), MState};
handle_call({stdout, JobId}, _From, MState) ->
    {reply, handle_request({output, job_stdout}, JobId, MState), MState};
handle_call({stderr, JobId}, _From, MState) ->
    {reply, handle_request({output, job_stderr}, JobId, MState), MState};
handle_call(Msg, From, MState) ->
    ?LOG_DEBUG("Unknown call message from ~p: ~p", [From, Msg]),
    {reply, ok, MState}.

handle_cast({event, EventType, EventData}, MState) ->
    handle_event(EventType, EventData),
    {noreply, MState};
handle_cast(Msg, MState) ->
    ?LOG_DEBUG("Unknown cast message: ~p", [Msg]),
    {noreply, MState}.

terminate(Reason, _) ->
    wm_utils:terminate_msg(?MODULE, Reason),
    wm_tcpserver:terminate(Reason, ?MODULE).

handle_info(_Info, Data) ->
    {noreply, Data}.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

%% ============================================================================
%% Implementation functions
%% ============================================================================

parse_args([], #mstate{} = MState) ->
    MState;
parse_args([{spool, Spool} | T], #mstate{} = MState) ->
    parse_args(T, MState#mstate{spool = Spool});
parse_args([{_, _} | T], MState) ->
    parse_args(T, MState).

handle_event(http_started, _) ->
    ?LOG_INFO("Initialize user REST API resources"),
    wm_http:add_route({api, wm_user_rest}, "/user"),
    wm_http:add_route({api, wm_user_rest}, "/user/node"),
    wm_http:add_route({api, wm_user_rest}, "/user/flavor"),
    wm_http:add_route({api, wm_user_rest}, "/user/remote"),
    wm_http:add_route({api, wm_user_rest}, "/user/job"),
    wm_http:add_route({api, wm_user_rest}, "/user/job/:id/stdout"),
    wm_http:add_route({api, wm_user_rest}, "/user/job/:id/stderr").

-spec handle_request(atom(), any(), #mstate{}) -> any().
handle_request({output, OutputType}, JobId, #mstate{spool = Spool}) ->
    ?LOG_DEBUG("Job ~p has been requested: ~p", [OutputType, JobId]),
    case wm_conf:select(job, {id, JobId}) of
        {ok, Job} ->
            FileName = wm_entity:get_attr(OutputType, Job),
            FullPath = filename:join([Spool, "output", JobId, FileName]),
            wm_utils:read_file(FullPath, [binary]);
        _ ->
            {error, "job not found"}
    end;
handle_request(submit, Args, #mstate{spool = Spool}) ->
    ?LOG_DEBUG("Job submission has been requested: ~n~p", [Args]),
    {JobScriptContent, Filename, Username} = Args,
    case wm_conf:select(user, {name, Username}) of
        {error, not_found} ->
            ?LOG_ERROR("User ~p not found, job submission failed", [Username]),
            R = io_lib:format("User ~p is not registred in the workload manager", [Username]),
            {string, [R]};
        {ok, User} ->
            % TODO verify user credentials using provided certificate
            JobId = wm_utils:uuid(v4),
            Cluster = wm_topology:get_subdiv(cluster),
            Job1 = wm_jobscript:parse(JobScriptContent),
            Job2 =
                wm_entity:set_attr([{cluster_id, wm_entity:get_attr(id, Cluster)},
                                    {state, ?JOB_STATE_QUEUED},
                                    {execution_path, Filename},
                                    {script_content, JobScriptContent},
                                    {user_id, wm_entity:get_attr(id, User)},
                                    {id, JobId},
                                    {job_stdout, "stdout.log"},
                                    {job_stderr, "stderr.log"},
                                    {submit_time, wm_utils:now_iso8601(without_ms)},
                                    {duration, 3600}],
                                   Job1),
            Job3 = set_defaults(Job2, Spool),
            Job4 = ensure_request_is_full(Job3),
            1 = wm_conf:update(Job4),
            {string, JobId}
    end;
handle_request(requeue, Args, _) ->
    ?LOG_DEBUG("Jobs requeue has been requested: ~p", [Args]),
    Results = requeue_jobs(Args, []),
    RequeuedFiltered =
        lists:filter(fun ({requeued, _}) ->
                             true;
                         (_) ->
                             false
                     end,
                     Results),
    RequeuedIds = lists:map(fun({_, ID}) -> ID end, RequeuedFiltered),
    NotFoundFiltered =
        lists:filter(fun ({not_found, _}) ->
                             true;
                         (_) ->
                             false
                     end,
                     Results),
    NotFoundIds = lists:map(fun({_, ID}) -> ID end, NotFoundFiltered),
    Msg = "Requeued: " ++ lists:join(", ", RequeuedIds) ++ "\n" ++ "Not found: " ++ lists:join(", ", NotFoundIds),
    {string, Msg};
handle_request(cancel, Args, _) ->
    ?LOG_DEBUG("Jobs cancellation has been requested: ~p", [Args]),
    Results = cancel_jobs(Args, []),
    CancelledFiltered =
        lists:filter(fun ({cancelled, _}) ->
                             true;
                         (_) ->
                             false
                     end,
                     Results),
    CancelledIds = lists:map(fun({_, ID}) -> ID end, CancelledFiltered),
    NotFoundFiltered =
        lists:filter(fun ({not_found, _}) ->
                             true;
                         (_) ->
                             false
                     end,
                     Results),
    NotFoundIds = lists:map(fun({_, ID}) -> ID end, NotFoundFiltered),
    Msg = "Cancelled: " ++ lists:join(", ", CancelledIds) ++ "\n" ++ "Not found: " ++ lists:join(", ", NotFoundIds),
    {string, Msg};
handle_request(list, {[flavor], Limit}, _) ->
    Nodes = wm_conf:select(node, {all, Limit}),
    NodesWithRemote = lists:filter(fun(X) -> wm_entity:get_attr(remote_id, X) =/= [] end, Nodes),
    NodesWithRemote;
handle_request(list, {Args, Limit}, _) ->
    ?LOG_DEBUG("List of ~p entities with limit ~p has been requested", [Args, Limit]),
    F = fun(X) -> wm_conf:select(X, {all, Limit}) end,
    lists:flatten([F(X) || X <- Args]);
handle_request(list, Args, _) ->
    ?LOG_DEBUG("List of ~p entities has been requested", [Args]),
    F = fun(X) -> wm_conf:select(X, all) end,
    lists:flatten([F(X) || X <- Args]);
handle_request(show, Args, _) ->
    ?LOG_DEBUG("Job show has been requested: ~p", [Args]),
    wm_conf:select(job, Args).

-spec ensure_request_is_full(#job{}) -> #job{}.
ensure_request_is_full(Job) ->
    ResourcesOld = wm_entity:get_attr(request, Job),
    ResourcesNew = add_missed_mandatory_request_resources(ResourcesOld),
    wm_entity:set_attr({request, ResourcesNew}, Job).

-spec add_missed_mandatory_request_resources([#resource{}]) -> [#resource{}].
add_missed_mandatory_request_resources(Resources) ->
    Names = lists:foldl(fun(R, Acc) -> [wm_entity:get_attr(name, R) | Acc] end, [], Resources),

    AddIfMissed =
        fun(Name, ResList, AddFun) ->
           case lists:member(Name, Names) of
               false ->
                   [AddFun() | ResList];
               true ->
                   ResList
           end
        end,

    Resources2 =
        AddIfMissed("node",
                    Resources,
                    fun() ->
                       ResNode1 = wm_entity:new(resource),
                       ResNode2 = wm_entity:set_attr({name, "node"}, ResNode1),
                       wm_entity:set_attr({count, 1}, ResNode2)
                    end),
    Resources3 =
        AddIfMissed("cpus",
                    Resources2,
                    fun() ->
                       ResCpu1 = wm_entity:new(resource),
                       ResCpu2 = wm_entity:set_attr({name, "cpus"}, ResCpu1),
                       wm_entity:set_attr({count, 1}, ResCpu2)
                    end),
    Resources3.

-spec requeue_jobs([job_id()], [{atom(), job_id()}]) -> [{atom(), job_id()}].
requeue_jobs([], Results) ->
    Results;
requeue_jobs([JobId | T], Results) ->
    Result =
        case wm_conf:select(job, {id, JobId}) of
            {ok, Job} ->
                UpdatedJob = wm_entity:set_attr({state, ?JOB_STATE_QUEUED}, Job),
                1 = wm_conf:update([UpdatedJob]),
                {requeued, JobId};
            _ ->
                {not_found, JobId}
        end,
    requeue_jobs(T, [Result | Results]).

cancel_jobs([], Results) ->
    Results;
cancel_jobs([JobId | T], Results) ->
    Result =
        case wm_conf:select(job, {id, JobId}) of
            {ok, Job} ->
                UpdatedJob = wm_entity:set_attr({state, ?JOB_STATE_CANCELLED}, Job),
                1 = wm_conf:update([UpdatedJob]),
                ok = wm_relocator:cancel_relocation(Job),
                %% TODO: free job's nodes if any have been already allocated
                {cancelled, JobId};
            _ ->
                {not_found, JobId}
        end,
    cancel_jobs(T, [Result | Results]).

-spec set_defaults(#job{}, string()) -> #job{}.
set_defaults(#job{workdir = [], id = JobId} = Job, Spool) ->
    set_defaults(wm_entity:set_attr({workdir, Spool ++ "/output/" ++ JobId}, Job), Spool);
set_defaults(#job{account_id = [], user_id = UserId} = Job, Spool) ->
    % If account is not specified by user during job submission then use the user's main account
    {ok, Account} = wm_conf:select(account, {admins, [UserId]}),
    AccountId = wm_entity:get_attr(id, Account),
    set_defaults(wm_entity:set_attr({account_id, AccountId}, Job), Spool);
set_defaults(Job, _) ->
    Job.
