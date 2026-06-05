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

%%% % @format

-module(edb_dap_request_set_breakpoints).

-moduledoc """
Handles Debug Adapter Protocol (DAP) setBreakpoints requests for the Erlang debugger.

The module follows the Microsoft Debug Adapter Protocol specification for
setBreakpoints requests: https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetBreakpoints
""".

-oncall("whatsapp_server_devx").
-compile(warn_missing_spec_all).

-behaviour(edb_dap_request).

-export([parse_arguments/1, handle/2]).

-export([source_template/0, format_breakpoint_error/1]).
-export([source_path_to_modules/1]).

%% ------------------------------------------------------------------
%% Types
%% ------------------------------------------------------------------

%%% https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetBreakpoints
-type arguments() :: #{
    %% The source location of the breakpoints; either `source.path` or
    %% `source.sourceReference` must be specified.
    source := edb_dap:source(),

    %% The code locations of the breakpoints.
    breakpoints => [sourceBreakpoint()],

    % Deprecated
    lines => [number()],

    %% A value of true indicates that the underlying source has been modified
    %% which results in new breakpoint locations.
    sourceModified => boolean()
}.
-type response() :: #{breakpoints := [breakpoint()]}.

%%% https://microsoft.github.io/debug-adapter-protocol/specification#Types_Breakpoint
-type breakpoint() :: #{
    %% The identifier for the breakpoint. It is needed if breakpoint events are
    %% used to update or remove breakpoints.
    id => number(),

    %% If true, the breakpoint could be set (but not necessarily at the desired
    %% location.
    verified := boolean(),

    %% A message about the state of the breakpoint.
    %% This is shown to the user and can be used to explain why a breakpoint could
    %% not be verified.
    message => binary(),

    %% The source where the breakpoint is located.
    source => edb_dap:source(),

    %% The start line of the actual range covered by the breakpoint.
    line => number(),

    %% Start position of the source range covered by the breakpoint. It is
    %% measured in UTF-16 code units and the client capability `columnsStartAt1`
    %% determines whether it is 0- or 1-based.
    column => number(),

    %% The end line of the actual range covered by the breakpoint.
    endLine => number(),

    %% End position of the source range covered by the breakpoint. It is measured
    %% in UTF-16 code units and the client capability `columnsStartAt1` determines
    %% whether it is 0- or 1-based.
    %% If no end line is given, then the end column is assumed to be in the start
    %% line.
    endColumn => number(),

    %% A memory reference to where the breakpoint is set.
    instructionReference => binary(),

    %% The offset from the instruction reference.
    %% This can be negative.
    offset => number(),

    %%  A machine-readable explanation of why a breakpoint may not be verified. If
    %% a breakpoint is verified or a specific reason is not known, the adapter
    %% should omit this property. Possible values include:
    %%
    %% - `pending`: Indicates a breakpoint might be verified in the future, but
    %% the adapter cannot verify it in the current state.
    %% - `failed`: Indicates a breakpoint was not able to be verified, and the
    %% adapter does not believe it can be verified without intervention.
    %% Values: 'pending', 'failed'
    reason => pending | failed
}.

%%% https://microsoft.github.io/debug-adapter-protocol/specification#Types_SourceBreakpoint
-type sourceBreakpoint() :: #{
    %% The source line of the breakpoint or logpoint.
    line := number(),

    %% Start position within source line of the breakpoint or logpoint. It is
    %% measured in UTF-16 code units and the client capability `columnsStartAt1`
    %% determines whether it is 0- or 1-based.
    column => number(),

    %% The expression for conditional breakpoints.
    %% It is only honored by a debug adapter if the corresponding capability
    %% `supportsConditionalBreakpoints` is true.
    condition => binary(),

    %% The expression that controls how many hits of the breakpoint are ignored.
    %% The debug adapter is expected to interpret the expression as needed.
    %% The attribute is only honored by a debug adapter if the corresponding
    %% capability `supportsHitConditionalBreakpoints` is true.
    %% If both this property and `condition` are specified, `hitCondition` should
    %% be evaluated only if the `condition` is met, and the debug adapter should
    %% stop only if both conditions are met.
    hitCondition => binary(),

    %% If this attribute exists and is non-empty, the debug adapter must not
    %% 'break' (stop)
    %% but log the message instead. Expressions within `{}` are interpolated.
    %% The attribute is only honored by a debug adapter if the corresponding
    %% capability `supportsLogPoints` is true.
    %% If either `hitCondition` or `condition` is specified, then the message
    %% should only be logged if those conditions are met.
    logMessage => binary(),

    %% The mode of this breakpoint. If defined, this must be one of the
    %% `breakpointModes` the debug adapter advertised in its `Capabilities`.
    mode => binary()
}.
-export_type([arguments/0, response/0]).
-export_type([breakpoint/0, sourceBreakpoint/0]).

-spec arguments_template() -> edb_dap_parse:template().
arguments_template() ->
    #{
        source => source_template(),
        breakpoints => {optional, edb_dap_parse:list(edb_dap_parse:template(sourceBreakpoint_template()))},
        lines => {optional, edb_dap_parse:list(edb_dap_parse:number())},
        sourceModified => {optional, edb_dap_parse:boolean()}
    }.

-spec source_template() -> edb_dap_parse:template().
source_template() ->
    #{
        name => {optional, edb_dap_parse:binary()},
        path => {optional, edb_dap_parse:binary()},
        sourceReference => {optional, edb_dap_parse:number()},
        presentationHint => {optional, edb_dap_parse:atoms([normal, emphasize, deemphasize])},
        origin => {optional, edb_dap_parse:binary()},
        sources => {optional, edb_dap_parse:list(fun(X) -> (edb_dap_parse:template(source_template()))(X) end)},
        % adapterData omitted on purpose, as this is a server generated value, and we never generate any
        checksums => {optional, edb_dap_parse:list(edb_dap_parse:template(checksum_template()))}
    }.

-spec sourceBreakpoint_template() -> edb_dap_parse:template().
sourceBreakpoint_template() ->
    #{
        line => edb_dap_parse:number(),
        column => {optional, edb_dap_parse:number()},
        condition => {optional, edb_dap_parse:binary()},
        hitCondition => {optional, edb_dap_parse:binary()},
        logMessage => {optional, edb_dap_parse:binary()},
        mode => {optional, edb_dap_parse:binary()}
    }.

-spec checksum_template() -> edb_dap_parse:template().
checksum_template() ->
    #{
        algorithm => edb_dap_parse:atoms(['MD5', 'SHA1', 'SHA256', 'timestamp']),
        checksum => edb_dap_parse:binary()
    }.

%% ------------------------------------------------------------------
%% Behaviour implementation
%% ------------------------------------------------------------------
-spec parse_arguments(edb_dap:arguments()) -> {ok, arguments()} | {error, Reason :: binary()}.
parse_arguments(Args) ->
    Template = arguments_template(),
    edb_dap_parse:parse(Template, Args, reject_unknown).

-spec handle(State, Args) -> edb_dap_request:reaction(response()) when
    State :: edb_dap_server:state(),
    Args :: arguments().
handle(#{state := configuring}, Args) ->
    set_breakpoints(Args);
handle(#{state := attached}, Args) ->
    set_breakpoints(Args);
handle(_UnexpectedState, _) ->
    edb_dap_request:unexpected_request().

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------
-spec set_breakpoints(Args) -> edb_dap_request:reaction(response()) when
    Args :: arguments().
set_breakpoints(Args = #{source := #{path := Path}}) ->
    Modules = source_path_to_modules(Path),
    SourceBreakpoints = maps:get(breakpoints, Args, []),
    SourceBreakpointLines = [Line || #{line := Line} <- SourceBreakpoints],

    LineResultsPerModule = [{Module, edb:set_breakpoints(Module, SourceBreakpointLines)} || Module <- Modules],

    Breakpoints = [breakpoint_response(Line, line_result(Line, LineResultsPerModule)) || Line <- SourceBreakpointLines],
    #{response => edb_dap_request:success(#{breakpoints => Breakpoints})}.

-spec source_path_to_modules(Path) -> [module()] when Path :: binary().
source_path_to_modules(Path) ->
    case filename:extension(Path) of
        ~".erl" ->
            [binary_to_atom(filename:basename(Path, ".erl"))];
        Ext when Ext =:= ~".ex"; Ext =:= ~".exs" ->
            elixir_source_path_to_modules(Path);
        _ ->
            [binary_to_atom(filename:basename(Path))]
    end.

-spec elixir_source_path_to_modules(Path) -> [module()] when Path :: binary().
elixir_source_path_to_modules(Path) ->
    Modules =
        case file:read_file(Path) of
            {ok, Source} -> elixir_modules_in_source(Source);
            {error, _} -> []
        end,
    case Modules of
        [] -> [elixir_module_from_path(Path)];
        _ -> Modules
    end.

-spec elixir_modules_in_source(binary()) -> [module()].
elixir_modules_in_source(Source) ->
    case
        re:run(Source, ~"(?m)^\\s*defmodule\\s+([A-Z][A-Za-z0-9_]*(?:\\.[A-Z][A-Za-z0-9_]*)*)\\s+do\\b", [
            global,
            {capture, [1], binary}
        ])
    of
        {match, Matches} ->
            unique_modules([binary_to_atom(<<"Elixir.", Name/binary>>) || [Name] <- Matches]);
        nomatch ->
            []
    end.

-spec elixir_module_from_path(Path) -> module() when Path :: binary().
elixir_module_from_path(Path) ->
    Extension = filename:extension(Path),
    Base = filename:basename(Path, Extension),
    ModuleName = iolist_to_binary([capitalize(Segment) || Segment <- binary:split(Base, ~"_", [global])]),
    binary_to_atom(<<"Elixir.", ModuleName/binary>>).

-spec capitalize(binary()) -> binary().
capitalize(<<First, Rest/binary>>) when First >= $a, First =< $z ->
    <<(First - 32), Rest/binary>>;
capitalize(Other) ->
    Other.

-spec unique_modules([module()]) -> [module()].
unique_modules(Modules) ->
    unique_modules(Modules, #{}, []).

-spec unique_modules([module()], #{module() => []}, [module()]) -> [module()].
unique_modules([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_modules([Module | Rest], Seen, Acc) ->
    case Seen of
        #{Module := _} -> unique_modules(Rest, Seen, Acc);
        #{} -> unique_modules(Rest, Seen#{Module => []}, [Module | Acc])
    end.

-spec line_result(Line, LineResultsPerModule) -> ok | {error, edb:add_breakpoint_error()} when
    Line :: number(),
    LineResultsPerModule :: [{module(), edb:set_breakpoints_result()}].
line_result(Line, LineResultsPerModule) ->
    Results = [
        Result
     || {_Module, LineResults} <- LineResultsPerModule,
        {ResultLine, Result} <- LineResults,
        ResultLine =:= Line
    ],
    case lists:member(ok, Results) of
        true -> ok;
        false -> {error, preferred_error(Line, Results)}
    end.

-spec preferred_error(edb:line(), [ok | {error, edb:add_breakpoint_error()}]) -> edb:add_breakpoint_error().
preferred_error(Line, []) ->
    {badkey, Line};
preferred_error(_Line, Results) ->
    Errors = [Reason || {error, Reason} <- Results],
    case [Reason || Reason <- Errors, not is_module_not_found(Reason)] of
        [Reason | _] -> Reason;
        [] -> hd(Errors)
    end.

-spec is_module_not_found(edb:add_breakpoint_error()) -> boolean().
is_module_not_found({badkey, Module}) when is_atom(Module) ->
    true;
is_module_not_found(_) ->
    false.

-spec breakpoint_response(Line, Result) -> breakpoint() when
    Line :: number(),
    Result :: ok | {error, edb:add_breakpoint_error()}.
breakpoint_response(Line, Result) ->
    case Result of
        ok ->
            #{line => Line, verified => true};
        {error, Reason} ->
            Message = format_breakpoint_error(Reason),
            #{line => Line, verified => false, message => Message, reason => failed}
    end.

-spec format_breakpoint_error(Error) -> binary() when
    Error :: edb:add_breakpoint_error().
format_breakpoint_error(unsupported) ->
    ~"The node does not support setting breakpoints: +D is needed as emulator flag";
format_breakpoint_error({badkey, Mod}) when is_atom(Mod) ->
    ~"Module not found or failing to load";
format_breakpoint_error({unsupported, Mod}) when is_atom(Mod) ->
    ~"The module does not have support for setting breakpoints";
format_breakpoint_error({badkey, Line}) when is_integer(Line) ->
    ~"Line is not executable";
format_breakpoint_error({unsupported, Line}) when is_integer(Line) ->
    ~"Can't set a breakpoint on this line";
format_breakpoint_error(timeout_loading_module) ->
    ~"The module failed to be loaded in time; the process loading it may be paused".
