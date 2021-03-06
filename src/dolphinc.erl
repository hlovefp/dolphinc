%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(dolphinc).

-behaviour(gen_server).

%% API
-export([ start_link/0
        , start_link/1
        , login/3
        , run/2
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(st,
        { host :: inet:socket_address() | inet:hostname()
        , port :: inet:port_number()
        , sock :: port()
        , sid  :: binary()  %% Session ID
        , username :: undefined | binary()
        , password :: undefined | function()
        , parser :: term()
        }).

-type option()
        :: {host, Host :: inet:socket_address() | inet:hostname()} %% default to 127.0.0.1
         | {port, Port :: inet:port_number()} %% default to 8848
         .

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

start_link() ->
    start_link([]).

-spec start_link([option()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Options) ->
    gen_server:start_link(?MODULE, [Options], []).

-spec login(pid(), binary(), binary()) -> ok | {error, term()}.
login(C, Username, Password) ->
    gen_server:call(C, {login, Username, Password}).

-spec run(pid(), iodata())
  -> {ok, Data :: term(), Msgs :: [term()]}
   | {error, term()}.
run(C, Script) ->
    gen_server:call(C, {script, Script}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Options]) ->
    Host = proplists:get_value(host, Options, "127.0.0.1"),
    Port = proplists:get_value(port, Options, 8848),
    case gen_tcp:connect(Host, Port, [binary, {active, false}]) of
        {ok, Sock} ->
            _ = gen_tcp:send(Sock, fe_connect()),
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Bytes} ->
                    SId = fd_connect(Bytes),
                    St = #st{host = Host,
                             port = Port,
                             sock = Sock,
                             sid = SId,
                             parser = init_parse_state()
                            },
                    {ok, NSt} = may_do_login(St, Options),
                    {ok, NSt};
                {error, R} ->
                    {error, R}
            end;
        {error, R} ->
            {error, R}
    end.

handle_call({login, Username, Password}, _From, St) ->
    case do_login(Username, Password, St) of
        {error, Reason} ->
            shutdown({sock_err, Reason}, St);
        {ok, NSt} ->
            {reply, ok, NSt#st{username = Username, password = fun() -> Password end}}
    end;

handle_call({script, Script}, _From, St = #st{sock = Sock, sid = SId}) ->
    _ = gen_tcp:send(Sock, fe_script(SId, Script)),
    case recv_a_packet(St) of
        {error, Reason} ->
            shutdown({sock_err, Reason}, St);
        {ok, #{error := Err}, NSt} ->
            {reply, {error, Err}, NSt};
        {ok, #{data := Data}, NSt} ->
            {reply, {ok, Data, []}, NSt}
    end;

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

%% @private
may_do_login(St, Options) ->
    case {proplists:get_value(username, Options),
          proplists:get_value(password, Options)} of
        {undefined, undefined} ->
            {ok, St};
        {_, undefined} ->
            error(miss_password_option);
        {Username, Password} ->
            do_login(Username, Password, St)
    end.

%% @private
do_login(Username, Password, St = #st{sock = Sock, sid = SId}) ->
    Script = [<<"login(\"">>, Username, "\",\"", Password, "\")"],
    _ = gen_tcp:send(Sock, fe_script(SId, Script)),
    case recv_a_packet(St) of
        {error, Reason} -> {error, Reason};
        {ok, #{error := Err}, _} ->
            {error, Err};
        {ok, _, NSt} ->
            {ok, NSt#st{username = Username, password = fun() -> Password end}}
    end.

recv_a_packet(St = #st{sock = Sock, parser = PSt}) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Bytes} ->
            {ok, Pkt, NPSt} = parse(Bytes, PSt),
            {ok, Pkt, St#st{parser = NPSt}};
        {error, Reason} ->
            {error, Reason}
    end.

shutdown(Reason, St) ->
    {stop, {shutdown, Reason}, St}.

%%--------------------------------------------------------------------
%% Utils for Frame encoding

fe_connect() ->
    <<"API 0 8\nconnect\n">>.

fe_script(SId, Script) ->
    Len = integer_to_binary(iolist_size(Script) + 7),
    ["API ", SId, " ", Len, " / 0_1_4_2\n",
     "script\n",
     Script].

%%--------------------------------------------------------------------
%% Parser

init_parse_state() ->
    #{rest => <<>>}.

parse(In, PSt = #{rest := Rest}) ->
    Bytes = <<Rest/binary, In/binary>>,
    case binary:split(Bytes, <<"\n">>) of
        [Hdr, Rest1] ->
            [SId, Cnt0, Endian] = binary:split(Hdr, <<" ">>, [global]),
            Cnt = binary_to_integer(Cnt0),
            case binary:split(Rest1, <<"\n">>) of
                [<<"OK">>, Rest2] ->
                    Pkt = #{header => #{sid => SId, cnt => Cnt, ed => Endian},
                            data => []
                           },
                    case Cnt == 0 of
                        true ->
                            {ok, Pkt, PSt#{rest => Rest2}};
                        _ ->
                            error({not_supported_data_return, Rest2})
                    end;
                [Err, Rest2] ->
                    Pkt = #{header => #{sid => SId, cnt => Cnt, ed => Endian},
                            error => Err
                           },
                    {ok, Pkt, PSt#{rest => Rest2}}
            end;
        _ ->
            error({unknown_data_response, Bytes})
    end.

fd_connect(Bytes) ->
    case binary:split(Bytes, <<"\n">>, [global]) of
        [Hdr, <<"OK">>, _] ->
            [SId|_] = binary:split(Hdr, <<" ">>),
            SId;
        _ ->
            error({unknown_data_response, Bytes})
    end.
