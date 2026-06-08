%% Copyright (c) Meta Platforms, Inc. and affiliates.
%%
%% Licensed under the Apache License, Version 2.0 (the ~"License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an ~"AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% % @format

%% Tests for the ~"set_breakpoints" request of the EDB DAP server

-module(edb_dap_set_breakpoints_SUITE).

-oncall("whatsapp_server_devx").

-include_lib("assert/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([test_error_set_breakpoint_bad_line/1]).
-export([test_error_set_breakpoint_unknown_module/1]).
-export([test_non_elixir_extension_uses_module_name/1]).
-export([test_set_breakpoint_by_elixir_source/1]).
-export([test_set_breakpoint_by_module_name_when_source_lookup_unavailable/1]).

all() ->
    [
        test_error_set_breakpoint_bad_line,
        test_error_set_breakpoint_unknown_module,
        test_non_elixir_extension_uses_module_name,
        test_set_breakpoint_by_elixir_source,
        test_set_breakpoint_by_module_name_when_source_lookup_unavailable
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    edb_test_support:stop_all_peers(),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
test_error_set_breakpoint_bad_line(Config) ->
    {ok, Client, #{modules := #{foo := FooSrc}}} =
        edb_dap_test_support:start_session_via_launch(Config, #{
            modules => [
                {source, [
                    ~"-module(foo).             %L01\n",
                    ~"-export([go/0]).          %L02\n",
                    ~"                          %L03\n",
                    ~"go() ->                   %L04\n",
                    ~"    ok.                   %L05\n"
                ]}
            ]
        }),
    ok = edb_dap_test_support:configure(Client, []),

    Response = edb_dap_test_client:set_breakpoints(Client, #{
        source => #{path => FooSrc},
        breakpoints => [#{line => L} || L <- lists:seq(1, 6)]
    }),

    ?assertMatch(
        #{
            command := ~"setBreakpoints",
            type := response,
            success := true,
            body :=
                #{
                    breakpoints :=
                        [
                            #{
                                line := 1,
                                message := ~"Line is not executable",
                                reason := ~"failed",
                                verified := false
                            },
                            #{
                                line := 2,
                                message := ~"Line is not executable",
                                reason := ~"failed",
                                verified := false
                            },
                            #{
                                line := 3,
                                message := ~"Line is not executable",
                                reason := ~"failed",
                                verified := false
                            },
                            #{
                                line := 4,
                                message :=
                                    ~"Can't set a breakpoint on this line",
                                reason := ~"failed",
                                verified := false
                            },
                            #{
                                line := 5,
                                verified := true
                            },
                            #{
                                line := 6,
                                message := ~"Line is not executable",
                                reason := ~"failed",
                                verified := false
                            }
                        ]
                }
        },
        Response
    ),
    ok.

test_error_set_breakpoint_unknown_module(Config) ->
    {ok, Client, #{}} = edb_dap_test_support:start_session_via_launch(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),

    Response = edb_dap_test_client:set_breakpoints(Client, #{
        source => #{path => ~"/blah/blah/foo.erl"},
        breakpoints => [#{line => 42}]
    }),

    ?assertMatch(
        #{
            command := ~"setBreakpoints",
            type := response,
            success := true,
            body :=
                #{
                    breakpoints :=
                        [
                            #{
                                line := 42,
                                message := ~"Module not found or failing to load",
                                reason := ~"failed",
                                verified := false
                            }
                        ]
                }
        },

        Response
    ),
    ok.

test_non_elixir_extension_uses_module_name(Config) ->
    case elixir_ebin() of
        {ok, ElixirEbin} ->
            test_non_elixir_extension_uses_module_name(Config, ElixirEbin);
        {skip, _Reason} = Skip ->
            Skip
    end.

test_non_elixir_extension_uses_module_name(Config, ElixirEbin) ->
    SourcePath = filename:join(proplists:get_value(priv_dir, Config), "edb_not_elixir_source.erl"),
    Module = edb_not_elixir_source,
    Source = [
        ~"defmodule IgnoredModule do\n",
        ~"  def go do\n",
        ~"    :ok\n",
        ~"  end\n",
        ~"end\n",
        ~"\n"
    ],

    ok = file:write_file(SourcePath, Source),
    {ok, Client, #{peer := Peer, srcdir := SrcDir}} =
        edb_dap_test_support:start_session_via_launch(Config, #{
            extra_args => ["-pa", ElixirEbin]
        }),
    ok = edb_dap_test_support:configure(Client, []),
    ok = load_module_object(Peer, SrcDir, Module, module_object(Module, undefined, 6)),

    Response = edb_dap_test_client:set_breakpoints(Client, #{
        source => #{path => edb_test_support:safe_string_to_binary(SourcePath)},
        breakpoints => [#{line => 6}]
    }),

    ?assertMatch(
        #{
            command := ~"setBreakpoints",
            type := response,
            success := true,
            body := #{breakpoints := [#{line := 6, verified := true}]}
        },
        Response
    ),
    ok.

test_set_breakpoint_by_elixir_source(Config) ->
    case elixir_ebin() of
        {ok, ElixirEbin} ->
            test_set_breakpoint_by_elixir_source(Config, ElixirEbin);
        {skip, _Reason} = Skip ->
            Skip
    end.

test_set_breakpoint_by_elixir_source(Config, ElixirEbin) ->
    SourcePath = filename:join(proplists:get_value(priv_dir, Config), "breakpoint.ex"),
    Module1 = 'Elixir.EdbGenericSourceBreakpoint.One',
    Module2 = 'Elixir.EdbGenericSourceBreakpoint.Two',
    Module3 = edb_non_elixir_source_breakpoint,
    Source = [
        ~"defmodule EdbGenericSourceBreakpoint.One do\n",
        ~"  def go do\n",
        ~"    :ok\n",
        ~"  end\n",
        ~"end\n",
        ~"\n",
        ~"defmodule EdbGenericSourceBreakpoint.Two do\n",
        ~"  def go do\n",
        ~"    :ok\n",
        ~"  end\n",
        ~"end\n",
        ~"\n",
        ~"defmodule :edb_non_elixir_source_breakpoint do\n",
        ~"  def go do\n",
        ~"    :ok\n",
        ~"  end\n",
        ~"end\n"
    ],

    ok = file:write_file(SourcePath, Source),
    {ok, Client, #{peer := Peer, srcdir := SrcDir}} =
        edb_dap_test_support:start_session_via_launch(Config, #{
            extra_args => ["-pa", ElixirEbin]
        }),
    ok = edb_dap_test_support:configure(Client, []),
    ok = load_module_object(Peer, SrcDir, Module1, module_object(Module1, undefined, 3)),
    ok = load_module_object(Peer, SrcDir, Module2, module_object(Module2, undefined, 9)),
    ok = load_module_object(Peer, SrcDir, Module3, module_object(Module3, undefined, 15)),

    Response = edb_dap_test_client:set_breakpoints(Client, #{
        source => #{path => edb_test_support:safe_string_to_binary(SourcePath)},
        breakpoints => [#{line => 3}, #{line => 9}, #{line => 15}, #{line => 42}]
    }),

    ?assertMatch(
        #{
            command := ~"setBreakpoints",
            type := response,
            success := true,
            body :=
                #{
                    breakpoints :=
                        [
                            #{line := 3, verified := true},
                            #{line := 9, verified := true},
                            #{line := 15, verified := true},
                            #{
                                line := 42,
                                message := ~"Line is not executable",
                                reason := ~"failed",
                                verified := false
                            }
                        ]
                }
        },
        Response
    ),
    ok.

test_set_breakpoint_by_module_name_when_source_lookup_unavailable(Config) ->
    SourcePath = filename:join(proplists:get_value(priv_dir, Config), "edb_no_source_breakpoint.ex"),
    Module = edb_no_source_breakpoint,

    {ok, Client, #{peer := Peer, srcdir := SrcDir}} = edb_dap_test_support:start_session_via_launch(Config, #{}),
    ok = edb_dap_test_support:configure(Client, []),
    ok = load_module_object(Peer, SrcDir, Module, module_object(Module, undefined, 6)),

    Response = edb_dap_test_client:set_breakpoints(Client, #{
        source => #{path => edb_test_support:safe_string_to_binary(SourcePath)},
        breakpoints => [#{line => 6}]
    }),

    ?assertMatch(
        #{
            command := ~"setBreakpoints",
            type := response,
            success := true,
            body := #{breakpoints := [#{line := 6, verified := true}]}
        },
        Response
    ),
    ok.

elixir_ebin() ->
    case os:find_executable("elixir") of
        false ->
            {skip, elixir_not_found};
        _Elixir ->
            LibDir = string:trim(os:cmd("elixir -e 'IO.write(:code.lib_dir(:elixir))'")),
            Ebin = filename:join(LibDir, "ebin"),
            case filelib:is_dir(Ebin) of
                true -> {ok, Ebin};
                false -> {skip, elixir_ebin_not_found}
            end
    end.

load_module_object(Peer, SrcDir, Module, Beam) ->
    BeamFile = filename:join([filename:dirname(SrcDir), "ebin", atom_to_list(Module) ++ ".beam"]),
    ok = file:write_file(BeamFile, Beam),
    {module, Module} = peer:call(Peer, code, ensure_loaded, [Module]),
    ok.

module_object(Module, SourcePath, ExecutableLine) ->
    Forms = [
        {attribute, 1, module, Module},
        {attribute, 2, export, [{go, 0}]},
        {function, ExecutableLine - 1, go, 0, [
            {clause, ExecutableLine - 1, [], [], [{atom, ExecutableLine, ok}]}
        ]}
    ],
    CompileOpts =
        case SourcePath of
            undefined -> [return, binary, beam_debug_info];
            _ -> [return, binary, beam_debug_info, {source, SourcePath}]
        end,
    Beam =
        case compile:forms(Forms, CompileOpts) of
            {ok, Module, Beam0} -> Beam0;
            {ok, Module, Beam0, []} -> Beam0
        end,
    Beam.
