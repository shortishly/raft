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

-module(tansu_timeout).
-export([election/0]).
-export([leader/0]).


election() ->
    crypto:rand_uniform(tansu_config:timeout(election_low),
                        tansu_config:timeout(election_high)).

leader() ->
    crypto:rand_uniform(tansu_config:timeout(leader_low),
                        tansu_config:timeout(leader_high)).
