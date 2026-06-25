%% Copyright (c) Meta Platforms, Inc. and affiliates.
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
%% % @format

-module(edb_dap_language_SUITE).

-oncall("whatsapp_server_devx").

-include_lib("assert/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([test_set_breakpoint_with_custom_dap_language/1]).
-export([test_step_in_uses_custom_dap_language_skip_targets/1]).

%% edb_dap_language callbacks
-export([init/0, source_to_modules/3, step_in_skip_targets/1]).

all() ->
    [
        test_set_breakpoint_with_custom_dap_language,
        test_step_in_uses_custom_dap_language_skip_targets
    ].

init_per_testcase(_TestCase, Config) ->
    {ok, _} = application:ensure_all_started(edb_core),
    ok = start_id_mappings(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok = stop_id_mappings(),
    _ = application:stop(edb_core),
    edb_test_support:stop_all_peers(),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
test_set_breakpoint_with_custom_dap_language(Config) ->
    Module = edb_custom_language_target,
    {ok, #{node := Node, cookie := Cookie}} = edb_test_support:start_peer_node(Config, #{
        modules => [
            {source, [
                ~"-module(edb_custom_language_target).\n",
                ~"-export([go/0]).\n",
                ~"go() ->\n",
                ~"    ok.\n"
            ]}
        ]
    }),
    ok = edb:attach(#{node => Node, cookie => Cookie}),

    SourcePath = ~"custom://source.edbtest",
    BreakpointLines = [4],
    DapLanguageState0 = #{
        modules_by_source => #{SourcePath => [Module]},
        source_lookups => []
    },
    Reaction = edb_dap_request_set_breakpoints:handle(
        #{state => attached, dap_language => ?MODULE, dap_language_state => DapLanguageState0},
        #{
            source => #{path => SourcePath},
            breakpoints => [#{line => Line} || Line <- BreakpointLines]
        }
    ),

    ?assertMatch(
        #{
            response :=
                #{
                    success := true,
                    body := #{breakpoints := [#{line := 4, verified := true}]}
                },
            new_state := #{
                dap_language_state := #{source_lookups := [{SourcePath, BreakpointLines}]}
            }
        },
        Reaction
    ),
    ok.

test_step_in_uses_custom_dap_language_skip_targets(Config) ->
    Module = edb_custom_language_step_target,
    {ok, #{peer := Peer, node := Node, cookie := Cookie}} = edb_test_support:start_peer_node(Config, #{
        modules => [
            {source, [
                ~"-module(edb_custom_language_step_target).     %L01\n",
                ~"-export([go/0]).                              %L02\n",
                ~"go() ->                                       %L03\n",
                ~"    f(23) + g(24).                            %L04\n",
                ~"f(X) ->                                       %L05\n",
                ~"    X + 1.                                    %L06\n",
                ~"g(X) ->                                       %L07\n",
                ~"    X + 2.                                    %L08\n"
            ]}
        ]
    }),
    ok = edb:attach(#{node => Node, cookie => Cookie}),

    ok = edb:add_breakpoint(Module, 4),
    erlang:spawn(fun() -> peer:call(Peer, Module, go, []) end),
    {ok, paused} = edb:wait(),
    [{Pid, #{line := 4}}] = maps:to_list(edb:get_breakpoints_hit()),

    ok = edb:clear_breakpoint(Module, 4),
    ThreadId = edb_dap_id_mappings:pid_to_thread_id(Pid),
    DapLanguageState0 = #{
        step_in_skip_targets => [{Module, f, 1}],
        step_in_skip_target_calls => 0
    },
    Reaction = edb_dap_request_next:stepper(
        #{state => attached, dap_language => ?MODULE, dap_language_state => DapLanguageState0},
        ThreadId,
        'step-in'
    ),

    ?assertMatch(
        #{
            response := #{success := true},
            new_state := #{dap_language_state := #{step_in_skip_target_calls := 1}}
        },
        Reaction
    ),

    {ok, paused} = edb:wait(),
    {ok, [#{mfa := {Module, g, 1}, line := 8} | _]} = edb:stack_frames(Pid),
    ok.

%%--------------------------------------------------------------------
%% edb_dap_language callbacks
%%--------------------------------------------------------------------
init() ->
    #{source_lookups => []}.

source_to_modules(Path, Lines, State0 = #{modules_by_source := ModulesBySource}) ->
    Modules = maps:get(Path, ModulesBySource),
    SourceLookups = maps:get(source_lookups, State0),
    State1 = State0#{source_lookups => SourceLookups ++ [{Path, Lines}]},
    {Modules, State1}.

step_in_skip_targets(State) ->
    SkipTargets = maps:get(step_in_skip_targets, State, []),
    Calls = maps:get(step_in_skip_target_calls, State, 0),
    {SkipTargets, State#{step_in_skip_target_calls => Calls + 1}}.

start_id_mappings() ->
    ok = start_id_mapping(fun edb_dap_id_mappings:start_link_thread_ids_server/0),
    ok = start_id_mapping(fun edb_dap_id_mappings:start_link_frame_ids_server/0),
    ok = start_id_mapping(fun edb_dap_id_mappings:start_link_var_reference_ids_server/0),
    ok.

start_id_mapping(StartFun) ->
    case StartFun() of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

stop_id_mappings() ->
    ok = stop_id_mapping(edb_dap_thread_id_mappings),
    ok = stop_id_mapping(edb_dap_frame_id_mappings),
    ok = stop_id_mapping(edb_dap_vars_ref_mappings),
    ok.

stop_id_mapping(Name) ->
    case erlang:whereis(Name) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.
