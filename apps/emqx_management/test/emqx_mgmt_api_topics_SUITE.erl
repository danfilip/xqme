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
-module(emqx_mgmt_api_topics_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite(),
    Config.

end_per_suite(_) ->
    emqx_mgmt_api_test_util:end_suite().

t_nodes_api(_) ->
    Node = atom_to_binary(node(), utf8),
    Topic = <<"test_topic">>,
    {ok, Client} = emqtt:start_link(#{
        username => <<"routes_username">>, clientid => <<"routes_cid">>
    }),
    {ok, _} = emqtt:connect(Client),
    {ok, _, _} = emqtt:subscribe(Client, Topic),

    %% list all
    Path = emqx_mgmt_api_test_util:api_path(["topics"]),
    {ok, Response} = emqx_mgmt_api_test_util:request_api(get, Path),
    RoutesData = emqx_json:decode(Response, [return_maps]),
    Meta = maps:get(<<"meta">>, RoutesData),
    ?assertEqual(1, maps:get(<<"page">>, Meta)),
    ?assertEqual(emqx_mgmt:max_row_limit(), maps:get(<<"limit">>, Meta)),
    ?assertEqual(1, maps:get(<<"count">>, Meta)),
    Data = maps:get(<<"data">>, RoutesData),
    Route = erlang:hd(Data),
    ?assertEqual(Topic, maps:get(<<"topic">>, Route)),
    ?assertEqual(Node, maps:get(<<"node">>, Route)),

    %% exact match
    Topic2 = <<"test_topic_2">>,
    {ok, _, _} = emqtt:subscribe(Client, Topic2),
    QS = uri_string:compose_query([
        {"topic", Topic2},
        {"node", atom_to_list(node())}
    ]),
    Headers = emqx_mgmt_api_test_util:auth_header_(),
    {ok, MatchResponse} = emqx_mgmt_api_test_util:request_api(get, Path, QS, Headers),
    MatchData = emqx_json:decode(MatchResponse, [return_maps]),
    ?assertMatch(
        #{<<"count">> := 1, <<"page">> := 1, <<"limit">> := 100},
        maps:get(<<"meta">>, MatchData)
    ),
    ?assertMatch(
        [#{<<"topic">> := Topic2, <<"node">> := Node}],
        maps:get(<<"data">>, MatchData)
    ),

    %% get topics/:topic
    RoutePath = emqx_mgmt_api_test_util:api_path(["topics", Topic]),
    {ok, RouteResponse} = emqx_mgmt_api_test_util:request_api(get, RoutePath),
    RouteData = emqx_json:decode(RouteResponse, [return_maps]),
    ?assertEqual(Topic, maps:get(<<"topic">>, RouteData)),
    ?assertEqual(Node, maps:get(<<"node">>, RouteData)).
