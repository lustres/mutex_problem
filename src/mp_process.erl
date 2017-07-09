%%%-------------------------------------------------------------------
%% @doc mutex_problem process
%% @end
%%%-------------------------------------------------------------------
-module(mp_process).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {queue :: ordsets:ordset({non_neg_integer(), pos_integer()}),
                time  :: non_neg_integer(),
                id    :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(ID :: non_neg_integer()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(ID) ->
  gen_server:start_link({local, mp_lib:server_id(ID)}, ?MODULE, [ID], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([ID]) ->
  {ok, #state{time = 0, id = ID, queue = ordsets:from_list([{0, 1}])}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(Msg = {require, _}, From, S) ->
  gen_server:reply(From, S#state.time),
  {noreply, state_for_msg(Msg, S)};

%%--------------------------------------------------------------------

handle_call(Msg = {release, _}, From, S) ->
  gen_server:reply(From, ok),
  {noreply, state_for_msg(Msg, S)};

%%--------------------------------------------------------------------

handle_call(Request, From, State) ->
  mp_lib:unknown_msg(call, {From, Request}),
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(require, S) ->
  {NewState, Times} = broad_call(require, S),
  {noreply, tick(NewState, lists:max(Times))};

%%--------------------------------------------------------------------

handle_cast(release, S) ->
  {NewState, _Times} = broad_call(release, S),
  {noreply, NewState};

%%--------------------------------------------------------------------

handle_cast({notify, Msg}, S) ->
  {noreply, state_for_msg(Msg, S), 0};

%%--------------------------------------------------------------------

handle_cast(Request, State) ->
  mp_lib:unknown_msg(cast, Request),
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(timeout, S = #state{queue = [{_Time, ID} | _], id = ID}) ->
  mp_res:acquire(self()),
  timer:apply_after(1000, gen_server, cast, [self(), release]),
  {noreply, S};

%%--------------------------------------------------------------------

handle_info(Info, State) ->
  mp_lib:unknown_msg(info, Info),
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec(state_for_msg({Type :: require|release,
                      {Time :: pos_integer(), ID :: pos_integer()}},
                    State :: #state{}) -> #state{}).
state_for_msg({require, Msg = {Time, _ID}}, S = #state{queue = Q}) ->
  tick(S#state{queue = ordsets:add_element(Msg, Q)}, Time);

%%--------------------------------------------------------------------

state_for_msg({release, {Time, ID}}, S = #state{queue = Q}) ->
  NewS = S#state{queue = ordsets:filter(fun({_, P}) -> P =/= ID end, Q)},
  tick(NewS, Time).

%%--------------------------------------------------------------------
%% @doc
%% Send {require, Mgs} or {release, Msg} to all processes.
%%
%% @end
%%--------------------------------------------------------------------
-spec(broad_call(Type :: require | release, State :: #state{})
      -> {NewState :: #state{}, [term()]}).
broad_call(Type, State) ->
  NewState = tick(State),
  Process = get_processes(),
  Msg = {NewState#state.time, NewState#state.id},
  R = [notify(Pid, {Type, Msg}) || Pid <- Process],
  {NewState, R}.

%%--------------------------------------------------------------------
%% @doc
%% Send Msg to all processes.
%% gen_server:call will block when call self, it will cause timeout
%% This function will call other processes while cast to self.
%%
%% @end
%%--------------------------------------------------------------------
-spec(notify(pid(), Msg :: term()) -> non_neg_integer()).
notify(Pid, Msg) when Pid =:= self() ->
  gen_server:cast(Pid, {notify, Msg}),
  %% min pos_integer()
  0;

%%--------------------------------------------------------------------

notify(Pid, Msg) ->
  gen_server:call(Pid, Msg).

%%--------------------------------------------------------------------
%% @doc
%% Increase local time
%%
%% @end
%%--------------------------------------------------------------------
-spec(tick(State :: #state{}) -> NewState :: #state{}).
tick(S = #state{time = T}) ->
  S#state{time = T + 1}.

%%--------------------------------------------------------------------
%% @doc
%% Increase local to timestamp
%%
%% @end
%%--------------------------------------------------------------------
-spec(tick(State :: #state{}, Timestamp :: non_neg_integer()) -> NewState :: #state{}).
tick(S = #state{time = T}, Timestamp) ->
  S#state{time = max(T, Timestamp) + 1}.

%%--------------------------------------------------------------------
%% @doc
%% Get all processes
%%
%% @end
%%--------------------------------------------------------------------
-spec(get_processes() -> [Process :: pid()]).
get_processes() ->
  Children = supervisor:which_children(mp_processes_sup),
  [element(2, C) || C <- Children].
