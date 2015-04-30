-module(vmq_bench_con).
-include_lib("emqtt_commons/include/emqtt_frame.hrl").

-behaviour(gen_server).

%% API functions
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {host,
                port,
                socket,
                client_id,
                connect_opts,
                topic,
                qos,
                keepalive,
                parser_state=emqtt_frame:initial_state(),
                counters=vmq_bench_stats:init_counters(con)}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Config) ->
    gen_server:start_link(?MODULE, [Config], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Config]) ->
    {A, B, C} = now(),
    random:seed(A, B, C),
    StartAfter = proplists:get_value(start_after, Config, 0),
    Hosts = proplists:get_value(hosts, Config, [{"localhost", 1883}]),
    ConnectOpts = proplists:get_value(connect_opts, Config, []),
    ClientId = proplists:get_value(client_id, ConnectOpts,
                                   "vmq-con-" ++ integer_to_list(erlang:phash2({A,B,C}))),
    Keepalive = proplists:get_value(keepalive, ConnectOpts, 60), %% packet.erl uses 60 as default
    erlang:send_after(Keepalive  * 1000, self(), ping),

    Topics = proplists:get_value(topics, Config, [{"/test/topic", 0}]),
    {Topic, QoS} = lists:nth(random:uniform(length(Topics)), Topics),
    {Host, Port} = lists:nth(random:uniform(length(Hosts)), Hosts),

    case proplists:get_value(stop_after, Config, 0) of
        0 -> ok;
        StopAfter when is_integer(StopAfter) ->
            erlang:send_after(StopAfter, self(), stop_now)
    end,
    {ok, #state{host=Host,
                port=Port,
                client_id=ClientId,
                connect_opts=ConnectOpts,
                keepalive=Keepalive,
                topic=Topic,
                qos=QoS}, StartAfter}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, #state{socket=undefined} = State) ->
    #state{client_id=ClientId,
           host=Host,
           port=Port,
           topic=Topic,
           qos=QoS,
           connect_opts=ConnectOpts} = State,

    Connect = packet:gen_connect(ClientId, ConnectOpts),
    Connack = packet:gen_connack(),
    {ok, Socket} = packet:do_client_connect(Connect, Connack,
                                            [{hostname, Host}, {port, Port}]),
    Subscribe = packet:gen_subscribe(1, Topic, QoS),
    ok = gen_tcp:send(Socket, Subscribe),
    Suback = packet:gen_suback(1, QoS),
    ok = packet:expect_packet(Socket, "suback", Suback),
    inet:setopts(Socket, [{active, once}]),
    {noreply, State#state{socket=Socket}};
handle_info(ping, #state{socket=Socket, keepalive=Keepalive} = State) ->
    case Socket of
        undefined -> ignore;
        _ ->
            ok = gen_tcp:send(Socket, packet:gen_pingreq())
    end,
    erlang:send_after(Keepalive  * 1000, self(), ping),
    {noreply, State};
handle_info({tcp, Socket, Data}, #state{socket=Socket, parser_state=PS,
                                        topic=Topic, counters=Counters} = State) ->
    {NewPS, NewCounters} = process_bytes(PS, Data, Socket, Counters),
    case Topic of
        "long/lat" -> timer:sleep(500);
        _ -> ok
    end,

    inet:setopts(Socket, [{active, once}]),
    {noreply, State#state{parser_state=NewPS, counters=NewCounters}};
handle_info({tcp_closed, Socket}, #state{socket=Socket} = State) ->
    {stop, normal, State};
handle_info(stop_now, State) ->
    {stop, normal, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
process_bytes(PS, Data, Socket, Counters) ->
    L = byte_size(Data),
    case emqtt_frame:parse(Data, PS) of
        {more, MorePS} -> {MorePS, vmq_bench_stats:incr_counters(0, L, nil, Counters)};
        {ok, #mqtt_frame{
               fixed=#mqtt_frame_fixed{type=?PUBLISH, qos=QoS},
               variable=#mqtt_frame_publish{message_id=Mid},
               payload=Payload}, Rest} ->
            {LatPoint, _} = binary_to_term(Payload),
            case QoS of
                0 ->
                    process_bytes(emqtt_frame:initial_state(), Rest, Socket,
                                  vmq_bench_stats:incr_counters(1, L, LatPoint, Counters));
                1 ->
                    Puback = packet:gen_puback(Mid),
                    ok = gen_tcp:send(Socket, Puback),
                    process_bytes(emqtt_frame:initial_state(), Rest, Socket,
                                  vmq_bench_stats:incr_counters(1, L, LatPoint, Counters));
                2 ->
                    Pubrec = packet:gen_pubrec(Mid),
                    ok = gen_tcp:send(Socket, Pubrec),
                    process_bytes(emqtt_frame:initial_state(), Rest, Socket,
                                  vmq_bench_stats:incr_counters(0, L, LatPoint, Counters))
            end;
        {ok, #mqtt_frame{fixed=#mqtt_frame_fixed{type=?PUBCOMP}}, Rest} ->
            process_bytes(emqtt_frame:initial_state(), Rest, Socket,
                          vmq_bench_stats:incr_counters(1, L, nil, Counters));
        {ok, #mqtt_frame{}, Rest} ->
            process_bytes(emqtt_frame:initial_state(), Rest, Socket,
                          vmq_bench_stats:incr_counters(0, L, nil, Counters));
        {error, _} ->
            {emqtt_frame:initial_state(), Counters}
    end.
