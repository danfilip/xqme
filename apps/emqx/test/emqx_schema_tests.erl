%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_schema_tests).

-include_lib("eunit/include/eunit.hrl").

ssl_opts_dtls_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(
        #{
            versions => dtls_all_available
        },
        false
    ),
    Checked = validate(Sc, #{<<"versions">> => [<<"dtlsv1.2">>, <<"dtlsv1">>]}),
    ?assertMatch(
        #{
            versions := ['dtlsv1.2', 'dtlsv1'],
            ciphers := []
        },
        Checked
    ).

ssl_opts_tls_1_3_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Checked = validate(Sc, #{<<"versions">> => [<<"tlsv1.3">>]}),
    ?assertMatch(
        #{
            versions := ['tlsv1.3'],
            ciphers := [],
            handshake_timeout := _
        },
        Checked
    ).

ssl_opts_tls_for_ranch_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, true),
    Checked = validate(Sc, #{<<"versions">> => [<<"tlsv1.3">>]}),
    ?assertMatch(
        #{
            versions := ['tlsv1.3'],
            ciphers := [],
            handshake_timeout := _
        },
        Checked
    ).

ssl_opts_cipher_array_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Checked = validate(Sc, #{
        <<"versions">> => [<<"tlsv1.3">>],
        <<"ciphers">> => [
            <<"TLS_AES_256_GCM_SHA384">>,
            <<"ECDHE-ECDSA-AES256-GCM-SHA384">>
        ]
    }),
    ?assertMatch(
        #{
            versions := ['tlsv1.3'],
            ciphers := ["TLS_AES_256_GCM_SHA384", "ECDHE-ECDSA-AES256-GCM-SHA384"]
        },
        Checked
    ).

ssl_opts_cipher_comma_separated_string_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Checked = validate(Sc, #{
        <<"versions">> => [<<"tlsv1.3">>],
        <<"ciphers">> => <<"TLS_AES_256_GCM_SHA384,ECDHE-ECDSA-AES256-GCM-SHA384">>
    }),
    ?assertMatch(
        #{
            versions := ['tlsv1.3'],
            ciphers := ["TLS_AES_256_GCM_SHA384", "ECDHE-ECDSA-AES256-GCM-SHA384"]
        },
        Checked
    ).

ssl_opts_tls_psk_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Checked = validate(Sc, #{<<"versions">> => [<<"tlsv1.2">>]}),
    ?assertMatch(#{versions := ['tlsv1.2']}, Checked).

bad_cipher_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Reason = {bad_ciphers, ["foo"]},
    ?assertThrow(
        {_Sc, [#{kind := validation_error, reason := Reason}]},
        validate(Sc, #{
            <<"versions">> => [<<"tlsv1.2">>],
            <<"ciphers">> => [<<"foo">>]
        })
    ),
    ok.

validate(Schema, Data0) ->
    Sc = #{
        roots => [ssl_opts],
        fields => #{ssl_opts => Schema}
    },
    Data = Data0#{
        cacertfile => <<"cacertfile">>,
        certfile => <<"certfile">>,
        keyfile => <<"keyfile">>
    },
    #{ssl_opts := Checked} =
        hocon_tconf:check_plain(
            Sc,
            #{<<"ssl_opts">> => Data},
            #{atom_key => true}
        ),
    Checked.

ciphers_schema_test() ->
    Sc = emqx_schema:ciphers_schema(undefined),
    WSc = #{roots => [{ciphers, Sc}]},
    ?assertThrow(
        {_, [#{kind := validation_error}]},
        hocon_tconf:check_plain(WSc, #{<<"ciphers">> => <<"foo,bar">>})
    ).

bad_tls_version_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(#{}, false),
    Reason = {unsupported_tls_versions, [foo]},
    ?assertThrow(
        {_Sc, [#{kind := validation_error, reason := Reason}]},
        validate(Sc, #{<<"versions">> => [<<"foo">>]})
    ),
    ok.

ssl_opts_gc_after_handshake_test_rancher_listener_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(
        #{
            gc_after_handshake => false
        },
        _IsRanchListener = true
    ),
    ?assertThrow(
        {_Sc, [
            #{
                kind := validation_error,
                reason := unknown_fields,
                unknown := "gc_after_handshake"
            }
        ]},
        validate(Sc, #{<<"gc_after_handshake">> => true})
    ),
    ok.

ssl_opts_gc_after_handshake_test_not_rancher_listener_test() ->
    Sc = emqx_schema:server_ssl_opts_schema(
        #{
            gc_after_handshake => false
        },
        _IsRanchListener = false
    ),
    Checked = validate(Sc, #{<<"gc_after_handshake">> => <<"true">>}),
    ?assertMatch(
        #{
            gc_after_handshake := true
        },
        Checked
    ),
    ok.

to_ip_port_test_() ->
    Ip = fun emqx_schema:to_ip_port/1,
    [
        ?_assertEqual({ok, 80}, Ip("80")),
        ?_assertEqual({ok, 80}, Ip(":80")),
        ?_assertEqual({error, bad_ip_port}, Ip("localhost:80")),
        ?_assertEqual({ok, {{127, 0, 0, 1}, 80}}, Ip("127.0.0.1:80")),
        ?_assertEqual({error, bad_ip_port}, Ip("$:1900")),
        ?_assertMatch({ok, {_, 1883}}, Ip("[::1]:1883")),
        ?_assertMatch({ok, {_, 1883}}, Ip("::1:1883")),
        ?_assertMatch({ok, {_, 1883}}, Ip(":::1883"))
    ].

-define(T(CASE, EXPR), {CASE, fun() -> EXPR end}).

parse_server_test_() ->
    DefaultPort = ?LINE,
    DefaultOpts = #{default_port => DefaultPort},
    Parse2 = fun(Value0, Opts) ->
        Value = emqx_schema:convert_servers(Value0),
        Validator = emqx_schema:servers_validator(Opts, _Required = true),
        try
            Result = emqx_schema:parse_servers(Value, Opts),
            ?assertEqual(ok, Validator(Value)),
            Result
        catch
            throw:Throw ->
                %% assert validator throws the same exception
                ?assertThrow(Throw, Validator(Value)),
                %% and then let the test code validate the exception
                throw(Throw)
        end
    end,
    Parse = fun(Value) -> Parse2(Value, DefaultOpts) end,
    HoconParse = fun(Str0) ->
        {ok, Map} = hocon:binary(Str0),
        Str = emqx_schema:convert_servers(Map),
        Parse(Str)
    end,
    [
        ?T(
            "single server, binary, no port",
            ?assertEqual(
                [{"localhost", DefaultPort}],
                Parse(<<"localhost">>)
            )
        ),
        ?T(
            "single server, string, no port",
            ?assertEqual(
                [{"localhost", DefaultPort}],
                Parse("localhost")
            )
        ),
        ?T(
            "single server, list(string), no port",
            ?assertEqual(
                [{"localhost", DefaultPort}],
                Parse(["localhost"])
            )
        ),
        ?T(
            "single server, list(binary), no port",
            ?assertEqual(
                [{"localhost", DefaultPort}],
                Parse([<<"localhost">>])
            )
        ),
        ?T(
            "single server, binary, with port",
            ?assertEqual(
                [{"localhost", 9999}],
                Parse(<<"localhost:9999">>)
            )
        ),
        ?T(
            "single server, list(string), with port",
            ?assertEqual(
                [{"localhost", 9999}],
                Parse(["localhost:9999"])
            )
        ),
        ?T(
            "single server, string, with port",
            ?assertEqual(
                [{"localhost", 9999}],
                Parse("localhost:9999")
            )
        ),
        ?T(
            "single server, list(binary), with port",
            ?assertEqual(
                [{"localhost", 9999}],
                Parse([<<"localhost:9999">>])
            )
        ),
        ?T(
            "multiple servers, string, no port",
            ?assertEqual(
                [{"host1", DefaultPort}, {"host2", DefaultPort}],
                Parse("host1, host2")
            )
        ),
        ?T(
            "multiple servers, binary, no port",
            ?assertEqual(
                [{"host1", DefaultPort}, {"host2", DefaultPort}],
                Parse(<<"host1, host2,,,">>)
            )
        ),
        ?T(
            "multiple servers, list(string), no port",
            ?assertEqual(
                [{"host1", DefaultPort}, {"host2", DefaultPort}],
                Parse(["host1", "host2"])
            )
        ),
        ?T(
            "multiple servers, list(binary), no port",
            ?assertEqual(
                [{"host1", DefaultPort}, {"host2", DefaultPort}],
                Parse([<<"host1">>, <<"host2">>])
            )
        ),
        ?T(
            "multiple servers, string, with port",
            ?assertEqual(
                [{"host1", 1234}, {"host2", 2345}],
                Parse("host1:1234, host2:2345")
            )
        ),
        ?T(
            "multiple servers, binary, with port",
            ?assertEqual(
                [{"host1", 1234}, {"host2", 2345}],
                Parse(<<"host1:1234, host2:2345, ">>)
            )
        ),
        ?T(
            "multiple servers, list(string), with port",
            ?assertEqual(
                [{"host1", 1234}, {"host2", 2345}],
                Parse([" host1:1234 ", "host2:2345"])
            )
        ),
        ?T(
            "multiple servers, list(binary), with port",
            ?assertEqual(
                [{"host1", 1234}, {"host2", 2345}],
                Parse([<<"host1:1234">>, <<"host2:2345">>])
            )
        ),
        ?T(
            "unexpected multiple servers",
            ?assertThrow(
                "expecting_one_host_but_got: 2",
                emqx_schema:parse_server(<<"host1:1234, host2:1234">>, #{default_port => 1})
            )
        ),
        ?T(
            "multiple servers without ports invalid string list",
            ?assertThrow(
                "hostname_has_space",
                Parse2(["host1 host2"], #{no_port => true})
            )
        ),
        ?T(
            "multiple servers without ports invalid binary list",
            ?assertThrow(
                "hostname_has_space",
                Parse2([<<"host1 host2">>], #{no_port => true})
            )
        ),
        ?T(
            "multiple servers wihtout port, mixed list(binary|string)",
            ?assertEqual(
                ["host1", "host2"],
                Parse2([<<"host1">>, "host2"], #{no_port => true})
            )
        ),
        ?T(
            "no default port, missing port number in config",
            ?assertThrow(
                "missing_port_number",
                emqx_schema:parse_server(<<"a">>, #{})
            )
        ),
        ?T(
            "empty binary string",
            ?assertEqual(
                undefined,
                emqx_schema:parse_server(<<>>, #{no_port => true})
            )
        ),
        ?T(
            "empty array",
            ?assertEqual(
                undefined,
                emqx_schema:parse_servers([], #{no_port => true})
            )
        ),
        ?T(
            "empty binary array",
            ?assertThrow(
                "bad_host_port",
                emqx_schema:parse_servers([<<>>], #{no_port => true})
            )
        ),
        ?T(
            "HOCON value undefined",
            ?assertEqual(
                undefined,
                emqx_schema:parse_server(undefined, #{no_port => true})
            )
        ),
        ?T(
            "single server map",
            ?assertEqual(
                [{"host1.domain", 1234}],
                HoconParse("host1.domain:1234")
            )
        ),
        ?T(
            "multiple servers map",
            ?assertEqual(
                [{"host1.domain", 1234}, {"host2.domain", 2345}, {"host3.domain", 3456}],
                HoconParse("host1.domain:1234,host2.domain:2345,host3.domain:3456")
            )
        ),
        ?T(
            "no port expected valid port",
            ?assertThrow(
                "not_expecting_port_number",
                emqx_schema:parse_server("localhost:80", #{no_port => true})
            )
        ),
        ?T(
            "no port expected invalid port",
            ?assertThrow(
                "not_expecting_port_number",
                emqx_schema:parse_server("localhost:notaport", #{no_port => true})
            )
        ),

        ?T(
            "bad hostname",
            ?assertThrow(
                "expecting_hostname_but_got_a_number",
                emqx_schema:parse_server(":80", #{default_port => 80})
            )
        ),
        ?T(
            "bad port",
            ?assertThrow(
                "bad_port_number",
                emqx_schema:parse_server("host:33x", #{default_port => 33})
            )
        ),
        ?T(
            "bad host with port",
            ?assertThrow(
                "bad_host_port",
                emqx_schema:parse_server("host:name:80", #{default_port => 80})
            )
        ),
        ?T(
            "bad schema",
            ?assertError(
                "bad_schema",
                emqx_schema:parse_server("whatever", #{default_port => 10, no_port => true})
            )
        )
    ].

servers_validator_test() ->
    Required = emqx_schema:servers_validator(#{}, true),
    NotRequired = emqx_schema:servers_validator(#{}, false),
    ?assertThrow("cannot_be_empty", Required("")),
    ?assertThrow("cannot_be_empty", Required(<<>>)),
    ?assertThrow("cannot_be_empty", Required(undefined)),
    ?assertEqual(ok, NotRequired("")),
    ?assertEqual(ok, NotRequired(<<>>)),
    ?assertEqual(ok, NotRequired(undefined)),
    ok.

converter_invalid_input_test() ->
    ?assertEqual(undefined, emqx_schema:convert_servers(undefined)),
    %% 'foo: bar' is a valid HOCON value, but 'bar' is not a port number
    ?assertThrow("bad_host_port", emqx_schema:convert_servers(#{foo => bar})).

password_converter_test() ->
    ?assertEqual(undefined, emqx_schema:password_converter(undefined, #{})),
    ?assertEqual(<<"123">>, emqx_schema:password_converter(123, #{})),
    ?assertEqual(<<"123">>, emqx_schema:password_converter(<<"123">>, #{})),
    ?assertThrow("must_quote", emqx_schema:password_converter(foobar, #{})),
    ok.
