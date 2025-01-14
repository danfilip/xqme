%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc This module implements EMQX Bridge transport layer on top of MQTT protocol

-module(emqx_connector_mqtt_mod).

-export([
    start/1,
    send/2,
    send_async/3,
    stop/1,
    ping/1
]).

-export([
    ensure_subscribed/3,
    ensure_unsubscribed/2
]).

%% callbacks for emqtt
-export([
    handle_publish/3,
    handle_disconnected/2
]).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-define(ACK_REF(ClientPid, PktId), {ClientPid, PktId}).

%% Messages towards ack collector process
-define(REF_IDS(Ref, Ids), {Ref, Ids}).

%%--------------------------------------------------------------------
%% emqx_bridge_connect callbacks
%%--------------------------------------------------------------------

start(Config) ->
    Parent = self(),
    ServerStr = iolist_to_binary(maps:get(server, Config)),
    {Server, Port} = emqx_connector_mqtt_schema:parse_server(ServerStr),
    Mountpoint = maps:get(receive_mountpoint, Config, undefined),
    Subscriptions = maps:get(subscriptions, Config, undefined),
    Vars = emqx_connector_mqtt_msg:make_pub_vars(Mountpoint, Subscriptions),
    Handlers = make_hdlr(Parent, Vars, #{server => ServerStr}),
    Config1 = Config#{
        msg_handler => Handlers,
        host => Server,
        port => Port,
        force_ping => true,
        proto_ver => maps:get(proto_ver, Config, v4)
    },
    case emqtt:start_link(process_config(Config1)) of
        {ok, Pid} ->
            case emqtt:connect(Pid) of
                {ok, _} ->
                    try
                        ok = sub_remote_topics(Pid, Subscriptions),
                        {ok, #{client_pid => Pid, subscriptions => Subscriptions}}
                    catch
                        throw:Reason ->
                            ok = stop(#{client_pid => Pid}),
                            {error, error_reason(Reason, ServerStr)}
                    end;
                {error, Reason} ->
                    ok = stop(#{client_pid => Pid}),
                    {error, error_reason(Reason, ServerStr)}
            end;
        {error, Reason} ->
            {error, error_reason(Reason, ServerStr)}
    end.

error_reason(Reason, ServerStr) ->
    #{reason => Reason, server => ServerStr}.

stop(#{client_pid := Pid}) ->
    safe_stop(Pid, fun() -> emqtt:stop(Pid) end, 1000),
    ok.

ping(undefined) ->
    pang;
ping(#{client_pid := Pid}) ->
    emqtt:ping(Pid).

ensure_subscribed(#{client_pid := Pid, subscriptions := Subs} = Conn, Topic, QoS) when
    is_pid(Pid)
->
    case emqtt:subscribe(Pid, Topic, QoS) of
        {ok, _, _} -> Conn#{subscriptions => [{Topic, QoS} | Subs]};
        Error -> {error, Error}
    end;
ensure_subscribed(_Conn, _Topic, _QoS) ->
    %% return ok for now
    %% next re-connect should should call start with new topic added to config
    ok.

ensure_unsubscribed(#{client_pid := Pid, subscriptions := Subs} = Conn, Topic) when is_pid(Pid) ->
    case emqtt:unsubscribe(Pid, Topic) of
        {ok, _, _} -> Conn#{subscriptions => lists:keydelete(Topic, 1, Subs)};
        Error -> {error, Error}
    end;
ensure_unsubscribed(Conn, _) ->
    %% return ok for now
    %% next re-connect should should call start with this topic deleted from config
    Conn.

safe_stop(Pid, StopF, Timeout) ->
    MRef = monitor(process, Pid),
    unlink(Pid),
    try
        StopF()
    catch
        _:_ ->
            ok
    end,
    receive
        {'DOWN', MRef, _, _, _} ->
            ok
    after Timeout ->
        exit(Pid, kill)
    end.

send(#{client_pid := ClientPid}, Msg) ->
    emqtt:publish(ClientPid, Msg).

send_async(#{client_pid := ClientPid}, Msg, Callback) ->
    emqtt:publish_async(ClientPid, Msg, infinity, Callback).

handle_publish(Msg, undefined, _Opts) ->
    ?SLOG(error, #{
        msg =>
            "cannot_publish_to_local_broker_as"
            "_'ingress'_is_not_configured",
        message => Msg
    });
handle_publish(#{properties := Props} = Msg0, Vars, Opts) ->
    Msg = format_msg_received(Msg0, Opts),
    ?SLOG(debug, #{
        msg => "publish_to_local_broker",
        message => Msg,
        vars => Vars
    }),
    case Vars of
        #{on_message_received := {Mod, Func, Args}} ->
            _ = erlang:apply(Mod, Func, [Msg | Args]);
        _ ->
            ok
    end,
    maybe_publish_to_local_broker(Msg, Vars, Props).

handle_disconnected(Reason, Parent) ->
    Parent ! {disconnected, self(), Reason}.

make_hdlr(Parent, Vars, Opts) ->
    #{
        publish => {fun ?MODULE:handle_publish/3, [Vars, Opts]},
        disconnected => {fun ?MODULE:handle_disconnected/2, [Parent]}
    }.

sub_remote_topics(_ClientPid, undefined) ->
    ok;
sub_remote_topics(ClientPid, #{remote := #{topic := FromTopic, qos := QoS}}) ->
    case emqtt:subscribe(ClientPid, FromTopic, QoS) of
        {ok, _, _} -> ok;
        Error -> throw(Error)
    end.

process_config(Config) ->
    maps:without([conn_type, address, receive_mountpoint, subscriptions, name], Config).

maybe_publish_to_local_broker(Msg, Vars, Props) ->
    case emqx_map_lib:deep_get([local, topic], Vars, undefined) of
        %% local topic is not set, discard it
        undefined -> ok;
        _ -> emqx_broker:publish(emqx_connector_mqtt_msg:to_broker_msg(Msg, Vars, Props))
    end.

format_msg_received(
    #{
        dup := Dup,
        payload := Payload,
        properties := Props,
        qos := QoS,
        retain := Retain,
        topic := Topic
    },
    #{server := Server}
) ->
    #{
        id => emqx_guid:to_hexstr(emqx_guid:gen()),
        server => Server,
        payload => Payload,
        topic => Topic,
        qos => QoS,
        dup => Dup,
        retain => Retain,
        pub_props => printable_maps(Props),
        message_received_at => erlang:system_time(millisecond)
    }.

printable_maps(undefined) ->
    #{};
printable_maps(Headers) ->
    maps:fold(
        fun
            ('User-Property', V0, AccIn) when is_list(V0) ->
                AccIn#{
                    'User-Property' => maps:from_list(V0),
                    'User-Property-Pairs' => [
                        #{
                            key => Key,
                            value => Value
                        }
                     || {Key, Value} <- V0
                    ]
                };
            (K, V0, AccIn) ->
                AccIn#{K => V0}
        end,
        #{},
        Headers
    ).
