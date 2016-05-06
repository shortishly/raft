%% Copyright (c) 2016 Peter Morgan <peter.james.morgan@gmail.com>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(raft_sm_mnesia_kv).

-export([ckv_delete/3]).
-export([ckv_get/3]).
-export([ckv_set/5]).
-export([ckv_test_and_delete/4]).
-export([ckv_test_and_set/6]).
-export([expired/1]).
-export([install_snapshot/3]).
-export([new/0]).
-export([snapshot/3]).

-behaviour(raft_sm).

-include_lib("stdlib/include/qlc.hrl").

-record(?MODULE, {key, parent, expiry, value}).


new() ->
    case raft_mnesia:create_table(?MODULE, [{attributes,
                                             record_info(fields, ?MODULE)},
                                            {index, [parent]},
                                            {type, ordered_set}]) of
        ok ->
            case raft_sm_mnesia_expiry:new() of
                ok ->
                    {ok, ?MODULE};
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

ckv_get(Category, Key, ?MODULE = StateMachine) ->
    {do_get(Category, Key), StateMachine}.

ckv_delete(Category, Key, ?MODULE = StateMachine) ->
    {do_delete(Category, Key), StateMachine}.

ckv_set(Category, Key, Value, Options, ?MODULE = StateMachine) ->
    {do_set(Category, Key, Value, Options), StateMachine}.

ckv_test_and_delete(Category, Key, ExistingValue, ?MODULE = StateMachine) ->
    {do_test_and_delete(Category, Key, ExistingValue), StateMachine}.

ckv_test_and_set(Category, Key, ExistingValue, NewValue, TTL, ?MODULE = StateMachine) ->
    {do_test_and_set(Category, Key, ExistingValue, NewValue, TTL), StateMachine}.

expired(?MODULE = StateMachine) ->
    {do_expired(), StateMachine}.

snapshot(Name, LastApplied, ?MODULE = StateMachine) ->
    {do_snapshot(Name, LastApplied), StateMachine}.

install_snapshot(Name, Data, ?MODULE = StateMachine) ->
    {do_install_snapshot(Name, Data), StateMachine}.

do_get(Category, Key) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{value = Value}] ->
                            {ok, Value};

                        [] ->
                            {error, not_found}
                    end
            end).

do_delete(Category, Key) ->
    activity(
      fun
          () ->
                    recursive_remove(Category, Key)
            end).

recursive_remove(ParentCategory, ParentKey) ->
    Children = qlc:cursor(
                 qlc:q(
                   [Key || #?MODULE{key = Key, parent = Parent} <- mnesia:table(?MODULE),
                           Parent == {ParentCategory, ParentKey}])),
    cursor_remove(Children, qlc:next_answers(Children)),
    cancel_expiry(ParentCategory, ParentKey),
    case mnesia:read(?MODULE, {ParentCategory, ParentKey}) of
        [#?MODULE{value = Value}] ->
            mnesia:delete({?MODULE, {ParentCategory, ParentKey}}),
            raft_sm:notify(ParentCategory, ParentKey, #{deleted => Value}),
            ok;

        [] ->
            ok
    end.


cursor_remove(Cursor, []) ->
    qlc:delete_cursor(Cursor);
cursor_remove(Cursor, Answers) ->
    lists:foreach(
      fun
          ({Category, Key}) ->
                         recursive_remove(Category, Key)
                 end,
      Answers),
    cursor_remove(Cursor, qlc:next_answers(Cursor)).

cancel_expiry(Category, Key) ->
    case mnesia:read(?MODULE, {Category, Key}) of
        [#?MODULE{expiry = Previous}] when is_integer(Previous) ->
            raft_sm_mnesia_expiry:cancel(Category, Key, Previous);
        _ ->
            nop
    end.

do_set(Category, Key, Value, #{parent := Parent, ttl := TTL}) ->
    activity(
      fun
          () ->
                    cancel_expiry(Category, Key),
                    Expiry = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + TTL,
                    mnesia:write(#?MODULE{key = {Category, Key},
                                          value = Value,
                                          expiry = Expiry,
                                          parent = {Category, Parent}}),
                    raft_sm_mnesia_expiry:set(Category, Key, Expiry),
                    raft_sm:notify(Category, Key, #{event => set,
                                                    ttl => TTL,
                                                    value => Value}),
                    ok
            end);

do_set(Category, Key, Value, #{parent := Parent}) ->
    activity(
      fun
          () ->
                    cancel_expiry(Category, Key),
                    mnesia:write(#?MODULE{key = {Category, Key},
                                          value = Value,
                                          parent = {Category, Parent}}),
                    raft_sm:notify(Category, Key, #{event => set,
                                                    value => Value}),
                    ok
            end);

do_set(Category, Key, Value, #{}) ->
    activity(
      fun
          () ->
                    cancel_expiry(Category, Key),
                    mnesia:write(#?MODULE{key = {Category, Key},
                                          value = Value}),
                    raft_sm:notify(Category, Key, #{event => set,
                                                    value => Value}),
                    ok
            end).



do_test_and_set(Category, Key, undefined, NewValue, #{parent := Parent, ttl := TTL}) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{}] ->
                            error;

                        [] ->
                            Expiry = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + TTL,
                            mnesia:write(#?MODULE{key = {Category, Key},
                                                  value = NewValue,
                                                  expiry = Expiry,
                                                  parent = {Category, Parent}}),
                            raft_sm_mnesia_expiry:set(Category, Key, Expiry),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            ttl => TTL,
                                                            value => NewValue}),
                            ok
                    end
            end);


do_test_and_set(Category, Key, undefined, NewValue, #{parent := Parent}) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{}] ->
                            error;

                        [] ->
                            mnesia:write(#?MODULE{key = {Category, Key},
                                                  value = NewValue,
                                                  parent = {Category, Parent}}),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            value => NewValue}),
                            ok
                    end
            end);

do_test_and_set(Category, Key, undefined, NewValue, #{}) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{}] ->
                            error;

                        [] ->
                            mnesia:write(#?MODULE{key = {Category, Key},
                                                  value = NewValue}),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            value => NewValue}),
                            ok
                    end
            end);


do_test_and_set(Category, Key, ExistingValue, NewValue, #{ttl := TTL}) ->
    activity(
      fun
          () ->
                    Expiry = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + TTL,

                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{value = ExistingValue,
                                  expiry = Previous} = Existing] when is_integer(Previous) ->
                            cancel_expiry(Category, Key),
                            mnesia:write(Existing#?MODULE{value = NewValue,
                                                          expiry = Expiry}),
                            raft_sm_mnesia_expiry:set(Category, Key, Expiry),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            ttl => TTL,
                                                            old_value => ExistingValue,
                                                            value => NewValue}),
                            ok;


                        [#?MODULE{value = ExistingValue} = Existing] ->
                            mnesia:write(Existing#?MODULE{value = NewValue, expiry = Expiry}),
                            raft_sm_mnesia_expiry:set(Category, Key, Expiry),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            ttl => TTL,
                                                            old_value => ExistingValue,
                                                            value => NewValue}),
                            ok;


                        [] ->
                            error
                    end
            end);

do_test_and_set(Category, Key, ExistingValue, NewValue, #{}) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{value = ExistingValue,
                                  expiry = Previous} = Existing] when is_integer(Previous) ->
                            cancel_expiry(Category, Key),
                            mnesia:write(Existing#?MODULE{value = NewValue,
                                                          expiry = undefined}),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            old_value => ExistingValue,
                                                            value => NewValue}),
                            ok;

                        [#?MODULE{value = ExistingValue} = Existing] ->
                            mnesia:write(Existing#?MODULE{value = NewValue}),
                            raft_sm:notify(Category, Key, #{event => set,
                                                            old_value => ExistingValue,
                                                            value => NewValue}),
                            ok;

                        [] ->
                            error
                    end
            end).


do_test_and_delete(Category, Key, ExistingValue) ->
    activity(
      fun
          () ->
                    case mnesia:read(?MODULE, {Category, Key}) of
                        [#?MODULE{value = ExistingValue}] ->
                            recursive_remove(Category, Key);

                        [#?MODULE{}] ->
                            error;
                        [] ->
                            error
                    end
            end).

do_snapshot(Name, LastApplied) ->
    activity(
      fun
          () ->
                    case {raft_log:do_first(), raft_log:do_last()} of
                        {#{index := First}, #{index := Last}} when (First < LastApplied) andalso (Last >= LastApplied) ->
                            #{term := Term} = raft_log:do_read(LastApplied),
                            raft_log:do_delete(First, LastApplied),
                            raft_log:do_write(LastApplied, Term, #{m => raft_sm, f => apply_snapshot, a => [Name]}),
                            {ok, Checkpoint, _} = mnesia:activate_checkpoint([{min, tables(snapshot)}]),
                            ok = mnesia:backup_checkpoint(Checkpoint, Name),
                            ok = mnesia:deactivate_checkpoint(Checkpoint);

                        _ ->
                            ok
                    end
            end).

do_install_snapshot(Name, Data) ->
    ok = filelib:ensure_dir(Name),
    ok = file:write_file(Name, Data),
    {atomic, _} = mnesia:restore(Name, [{recreate_tables, tables(snapshot)}]),
    ok.

tables(snapshot) ->
    [?MODULE, raft_log, raft_sm_mnesia_expiry].


do_expired() ->
    activity(
      fun
          () ->
                    raft_sm_mnesia_expiry:expired()
            end).


activity(F) ->
    mnesia:activity(transaction, F).


